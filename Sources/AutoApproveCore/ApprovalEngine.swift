import Foundation
import Combine

@MainActor public final class ApprovalEngine: ObservableObject {
    @Published public private(set) var snapshot: EngineSnapshot
    @Published public private(set) var initialDiscoveryComplete = false
    public let paths: AppPaths
    private let store: AuditStore
    private let terminalReader: @Sendable ([String]) throws -> TerminalSnapshot
    private let claudeRegistryReader: @Sendable ([ProcessRecord]) -> [ClaudeSessionRegistration]
    private let processReader: @Sendable () throws -> [ProcessRecord]
    private var claudeParents: [String: String] = [:]
    private var recoveredClaudeStates = Set<String>()
    private var claudeHookObservedAt: [String: Date] = [:]
    private struct LiveClaudeHook {
        var request: ClaudeHookRequest
        var receipt: ClaudeHookReceipt
        var lastContact: Date
    }
    private var liveClaudeHooks: [String: LiveClaudeHook] = [:]
    private var parentSaveFailed = false
    private let codexQuestions = CodexQuestionCollector()
    private var codexCompletions = CodexCompletionTracker()
    private var claudeWorkIDs: [String: String] = [:]
    private let questionTransport: CodexReplyTransport
    private var replyingQuestions = Set<String>()
    private var readableQuestionSessions = Set<String>()
    private var questionThreadBySession: [String: String] = [:]
    private var restoredQuestionIDs = Set<String>()
    private var questionAutomationOverrides: [String: QuestionAutomation.Phase] = [:]
    private var automaticQuestionReplies: [String: AutomaticQuestionReply] = [:]
    private var questionAutomationStopped = false
    private struct AutomaticQuestionReply {
        var token: UUID
        var sessionID: String
        var question: QueuedQuestion
        var sending = false
        var deadline: Date
        var task: Task<Void, Never>
    }
    private var sessions: [String: AgentSession] = [:]
    private var sessionOrder: [String] = []
    private var inboxes: [String: SessionInbox] = [:]
    private var records: [ProcessRecord] = []
    private var server: SocketServer?
    private var pollTask: Task<Void, Never>?
    private var gitBranchTask: Task<Void, Never>?
    private var peers: [String: SocketConnection] = [:]
    private var bridges: [String: [JSONObject]] = [:]
    private var screens: [String: ScreenState] = [:]
    private var activityTrackers: [String: ActivityTracker] = [:]
    private var screenObservedAt: [String: Date] = [:]
    private var handledHookIDs: Set<String> = []
    private var hookIDOrder: [String] = []
    private var pendingActions: [String: (sessionID: String, event: AuditEvent, peerID: String, dispatchID: UUID, generation: String, requestIdentity: String)] = [:]
    private var terminalEnabled = false
    private var terminalPolling = false
    private var terminalPermissionBlocked = false
    private var terminalRetryAfter = Date.distantPast
    private var discovering = false
    private var revision: UInt64 = 0
    private struct ScreenState {
        var raw: String
        var prompt: ApprovalPrompt
        var attempted = false
        var generation: String
        var isCurrent = true
        var scheduledID: UUID?
        var validationFailures = 0
        var retryAfter: Date?
        var dispatchID: UUID?
        var reviewDetail: String?
    }

    public init(paths: AppPaths = AppPaths(), terminalReader: @escaping @Sendable ([String]) throws -> TerminalSnapshot = { try TerminalAdapter.screens(ttys: $0) }, questionTransport: CodexReplyTransport = .live, claudeRegistryReader: @escaping @Sendable ([ProcessRecord]) -> [ClaudeSessionRegistration] = { ClaudeSessionRegistry.read(records: $0) }, processReader: @escaping @Sendable () throws -> [ProcessRecord] = { try ProcessDiscovery.read() }) throws {
        self.paths = paths
        self.terminalReader = terminalReader
        self.questionTransport = questionTransport
        self.claudeRegistryReader = claudeRegistryReader
        self.processReader = processReader
        try paths.prepare()
        store = try AuditStore(path: paths.database)
        if let saved = store.value("claudeParents"), let parents = try? JSONDecoder().decode([String: String].self, from: Data(saved.utf8)) {
            claudeParents = parents
        }
        if let saved = store.value("sessionOrder"),
           let ids = try? JSONDecoder().decode([String].self, from: Data(saved.utf8)) {
            var seen = Set<String>()
            sessionOrder = ids.filter { seen.insert($0).inserted }
        }
        snapshot = EngineSnapshot(sessions: [], events: store.recent(), paused: store.value("paused") == "true", health: ConnectionHealth())
        snapshot.questionNotificationDelaySeconds = store.value("questionNotificationDelaySeconds").flatMap(Int.init)
        snapshot.health.claude = HookInstaller.isInstalled() ? "설치됨 · 세션 이벤트 대기" : "훅 설치 필요"
        // Restore only a connection the user explicitly enabled from the app.
        terminalEnabled = store.value("terminalEnabled") == "true"
        snapshot.health.terminalRequested = terminalEnabled
        if terminalEnabled { snapshot.health.terminal = "저장된 Terminal 연결 복원 중…" }
    }

    public func start(poll: Bool = true) throws {
        let socket = SocketServer(path: paths.socket, handler: { [weak self] message, peer in
            Task { @MainActor in self?.receive(message, from: peer) }
        }, disconnected: { [weak self] id in
            Task { @MainActor in self?.disconnect(id) }
        })
        try socket.start(); server = socket
        questionAutomationStopped = false
        reconcileAutomaticQuestionReplies()
        if poll {
            pollTask = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.refresh()
                    do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { break }
                }
            }
        }
    }
    public func stop() {
        revision &+= 1; pollTask?.cancel(); pollTask = nil
        gitBranchTask?.cancel(); gitBranchTask = nil
        questionAutomationStopped = true
        for id in Array(automaticQuestionReplies.keys) { cancelAutomaticQuestionReply(id) }
        server?.stop(); server = nil
    }

    private func ownerID(_ id: String) -> String? {
        var current = id, seen = Set<String>()
        while seen.insert(current).inserted {
            guard let session = sessions[current], session.phase != .ended else { return nil }
            guard let parent = claudeParents[current] else { return current }
            current = parent
        }
        return nil
    }

    private func effectiveAutomatic(_ id: String, fallback: AgentSession? = nil) -> Bool {
        if claudeParents[id] != nil {
            guard !parentSaveFailed, let owner = ownerID(id) else { return false }
            return sessions[owner]?.automatic == true
        }
        return (sessions[id] ?? fallback)?.automatic == true
    }

    private func groupIDs(_ id: String) -> [String] {
        guard let root = ownerID(id) else { return sessions[id] == nil ? [] : [id] }
        return sessions.keys.filter { $0 == root || ownerID($0) == root }.sorted()
    }

    private func hasBackgroundChildren(_ id: String) -> Bool {
        sessions.keys.contains { $0 != id && ownerID($0) == id }
    }

    private func reconcileClaudeParents(registrations: [ClaudeSessionRegistration]) {
        let found = ClaudeSessionRegistry.parents(sessions: Array(sessions.values), records: records, registrations: registrations)
        let next = claudeParents.merging(found) { _, new in new }
        guard next != claudeParents || parentSaveFailed else { return }
        claudeParents = next
        for parent in Set(found.values) where screens[parent] != nil {
            if sessions[parent]?.channel != .hook {
                clearScreen(parent)
                sessions[parent]?.setPhase(.unknown, detail: "메인·백그라운드 상태를 함께 확인합니다.")
            } else { screens.removeValue(forKey: parent) }
        }
        do {
            try store.set("claudeParents", String(decoding: try JSONEncoder().encode(next), as: UTF8.self))
            parentSaveFailed = false
        } catch { parentSaveFailed = true }
    }

    private func presentedSessions() -> [AgentSession] {
        let raw = sessions.values.map { value -> AgentSession in
            var session = value
            session.automatic = effectiveAutomatic(value.id)
            if claudeParents[value.id] != nil && ownerID(value.id) == nil && value.phase != .ended {
                session.detail = "메인 세션이 종료되었거나 연결을 확인할 수 없어 자동 승인을 멈췄습니다. 독립적으로 처리하려면 이 세션의 자동 승인을 다시 켜세요."
            }
            return session
        }
        func priority(_ phase: SessionPhase) -> Int {
            switch phase { case .input: return 6; case .approval: return 5; case .working: return 4; case .unknown: return 3; case .idle: return 2; case .ended: return 0 }
        }
        return raw.compactMap { value in
            if let root = ownerID(value.id), root != value.id { return nil }
            var parent = value
            let children = raw.filter { $0.id != value.id && ownerID($0.id) == value.id }.sorted {
                if priority($0.phase) != priority($1.phase) { return priority($0.phase) > priority($1.phase) }
                return $0.id < $1.id
            }
            guard !children.isEmpty else { return parent }
            parent.backgroundSessions = children; parent.ownPhase = value.phase
            parent.detail = "메인과 백그라운드의 질문·알림을 함께 표시합니다. 백그라운드 질문은 연결된 Claude 훅으로 처리합니다."
            if let lead = children.first, value.phase == .unknown || priority(lead.phase) > priority(value.phase) {
                parent.phase = lead.phase; parent.idleSince = lead.idleSince
                parent.backgroundMonitoring = lead.backgroundMonitoring
                parent.activityDetail = lead.activityDetail
            }
            parent.lastActivity = ([value] + children).map(\.lastActivity).max() ?? value.lastActivity
            parent.notices = ([value] + children).flatMap { $0.notices ?? [] }.sorted { $0.date > $1.date }
            if parentSaveFailed {
                parent.detail = "메인·백그라운드 연결을 저장하지 못해 백그라운드 자동 승인을 멈췄습니다. 저장 상태를 확인해주세요."
            }
            return parent
        }
    }

    private func reconcileClaudeActivities(_ registrations: [ClaudeSessionRegistration]) {
        var observed = Set<String>()
        for entry in registrations where entry.kind == "bg" {
            let id = entry.processID
            // While a synchronous hook waits here, Claude may still report the previous disk state.
            if liveClaudeHooks.values.contains(where: { $0.request.sessionID == id }) { continue }
            guard var session = sessions[id], session.agent == .claude, session.phase != .ended,
                  let activity = entry.activity else { continue }
            observed.insert(id)
            // A delayed disk update must not reopen a request just answered by a hook.
            guard activity.changedAt > (claudeHookObservedAt[id] ?? .distantPast) else { continue }
            let phase: SessionPhase
            let detail: String
            switch activity.status {
            case "waiting":
                phase = activity.waitingFor == "permission prompt" ? .approval : .input
                // The registry is updated after PreToolUse returns. Keep a current
                // hook's fuller question and identity instead of creating a second
                // notification (or replacing it with incomplete job metadata).
                if session.providerID == activity.providerID, session.pendingInTerminal,
                   session.pendingRequestID?.hasPrefix("hook:") == true,
                   session.phase == phase,
                   activity.questionSummary == nil || activity.questionSummary == session.pendingSummary { continue }
                detail = "이미 열려 있는 요청을 복원했습니다. 이번 요청은 터미널에서 답해주세요. 자동 승인이 켜져 있으면 다음 지원 질문부터 훅으로 응답합니다."
                session.pendingSummary = activity.questionSummary ?? (phase == .approval
                    ? "Claude가 실행 권한 확인을 기다리고 있습니다. 터미널에서 요청 내용을 확인해주세요."
                    : "Claude가 입력을 기다리고 있습니다. 질문 전문은 터미널에서 확인해주세요.")
                session.pendingRequestID = activity.requestID
                session.pendingInTerminal = true
            case "busy":
                phase = .working; detail = "Claude 백그라운드 작업이 진행 중입니다."
                session.pendingSummary = nil; session.pendingRequestID = nil; session.pendingInTerminal = false
            case "idle":
                phase = .idle; detail = "Claude 백그라운드 세션이 다음 지시를 기다리고 있습니다."
                session.pendingSummary = nil; session.pendingRequestID = nil; session.pendingInTerminal = false
            default: continue
            }
            session.providerID = activity.providerID
            session.setPhase(phase, detail: detail, at: activity.changedAt)
            sessions[id] = session
            recoveredClaudeStates.insert(id)
        }
        for id in recoveredClaudeStates.subtracting(observed) {
            if sessions[id]?.phase != .ended {
                sessions[id]?.setPhase(.unknown, detail: "Claude의 현재 상태를 다시 확인하고 있습니다.")
                sessions[id]?.pendingSummary = nil; sessions[id]?.pendingRequestID = nil
                sessions[id]?.pendingInTerminal = false
            }
            recoveredClaudeStates.remove(id)
        }
    }

    private func publish() {
        projectClaudeApprovals()
        reconcileAutomaticQuestionReplies()
        updateQuestionAutomationStates()
        updateInboxes()
        let ranks = Dictionary(uniqueKeysWithValues: sessionOrder.enumerated().map { ($0.element, $0.offset) })
        snapshot.sessions = presentedSessions().sorted {
            if ($0.phase == .ended) != ($1.phase == .ended) { return $0.phase != .ended }
            let left = ranks[$0.id] ?? Int.max, right = ranks[$1.id] ?? Int.max
            if left != right { return left < right }
            if $0.project != $1.project { return $0.project.localizedStandardCompare($1.project) == .orderedAscending }
            return $0.id < $1.id
        }
    }

    /// Reorder only the visible slots; filtered-out sessions keep their positions.
    /// IDs bind a native List move to the exact rows shown when it was requested.
    public func moveSessions(fromOffsets offsets: IndexSet, toOffset destination: Int, visibleIDs: [String]) throws {
        guard !offsets.isEmpty else { return }
        let current = snapshot.sessions.filter { $0.phase != .ended }.map(\.id)
        let visible = Set(visibleIDs)
        guard visible.count == visibleIDs.count,
              current.filter({ visible.contains($0) }) == visibleIDs,
              (0...visibleIDs.count).contains(destination),
              offsets.allSatisfy({ visibleIDs.indices.contains($0) }) else {
            throw AppError.message("터미널 목록이 변경되었습니다. 현재 목록에서 다시 이동해주세요.")
        }
        let moved = offsets.map { visibleIDs[$0] }
        var reordered = visibleIDs.enumerated().filter { !offsets.contains($0.offset) }.map(\.element)
        reordered.insert(contentsOf: moved, at: destination - offsets.filter { $0 < destination }.count)
        guard reordered != visibleIDs else { return }
        var iterator = reordered.makeIterator()
        let next = current.map { visible.contains($0) ? iterator.next()! : $0 }
        let json = String(decoding: try JSONEncoder().encode(next), as: UTF8.self)
        // Commit the preference before publishing so a failed save cannot look successful.
        try store.set("sessionOrder", json)
        sessionOrder = next
        publish()
    }

    public func setCustomization(_ id: String, value: SessionCustomization) throws {
        guard var session = sessions[id], session.phase != .ended else {
            throw AppError.message("이 세션이 종료되어 표시 설정을 저장할 수 없습니다. 현재 목록에서 세션을 다시 선택해주세요.")
        }
        let value = try value.normalized()
        let json = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        try store.set("customization:\(id)", json)
        session.customization = value.isEmpty ? nil : value
        sessions[id] = session
        publish()
    }

    public func markNotificationsRead(_ id: String) throws {
        var updated: [String: SessionInbox] = [:], values: [String: String] = [:]
        for member in groupIDs(id) {
            guard var inbox = inboxes[member], inbox.markRead() else { continue }
            values["inbox:\(member)"] = String(decoding: try JSONEncoder().encode(inbox), as: UTF8.self)
            updated[member] = inbox
        }
        guard !values.isEmpty else { return }
        try store.setValues(values)
        for (member, inbox) in updated {
            inboxes[member] = inbox
            sessions[member]?.notices = inbox.entries.isEmpty ? nil : inbox.entries
        }
        publish()
    }

    public func isNotificationRead(sessionID: String, sourceKey: String) -> Bool {
        inboxes[sessionID]?.isRead(sourceKey) ?? false
    }

    /// Refresh delayed badges without process discovery; used by native previews as well.
    public func refreshNotices() { publish() }

    public func setQuestionNotificationDelay(_ seconds: Int) throws {
        guard EngineSnapshot.questionNotificationDelayRange.contains(seconds) else {
            throw AppError.message("질문 알림 대기 시간은 1~3600초로 입력해주세요.")
        }
        try store.set("questionNotificationDelaySeconds", String(seconds))
        snapshot.questionNotificationDelaySeconds = seconds
    }

    private func restorePreferences(_ session: inout AgentSession) {
        session.automatic = store.value("automatic:\(session.id)") == "true"
        session.customization = nil
        if let saved = store.value("customization:\(session.id)"),
           let decoded = try? JSONDecoder().decode(SessionCustomization.self, from: Data(saved.utf8)),
           let value = try? decoded.normalized(), !value.isEmpty {
            session.customization = value
        }
        if let saved = store.value("inbox:\(session.id)"),
           let inbox = try? JSONDecoder().decode(SessionInbox.self, from: Data(saved.utf8)) {
            inboxes[session.id] = inbox
            session.notices = inbox.entries.isEmpty ? nil : inbox.entries
        } else { session.notices = nil }
    }

    private func updateInboxes() {
        var saveError: String?
        let now = Date()
        for id in Array(sessions.keys) {
            guard var session = sessions[id] else { continue }
            session.automatic = effectiveAutomatic(id)
            var candidates = AttentionRequest.candidates(session, paused: snapshot.paused).map {
                SessionInbox.Candidate(key: SessionNotice.key(.question, $0.key), kind: .question, summary: $0.summary)
            }
            if session.phase != .ended, let completion = session.completion, now.timeIntervalSince(completion.date) <= 300 {
                candidates.append(.init(key: SessionNotice.key(.completion, completion.id), kind: .completion, summary: completion.summary))
            }
            var inbox = inboxes[id] ?? SessionInbox()
            let observed = session.phase == .ended || (session.phase != .unknown &&
                (session.agent != .codex || (session.codexQuestionsObservedAt != nil && session.codexQuestionsError == nil)))
            guard inbox.update(candidates, at: now, reconcilesAbsence: observed) else { continue }
            do {
                try store.set("inbox:\(id)", String(decoding: try JSONEncoder().encode(inbox), as: UTF8.self))
                inboxes[id] = inbox
                sessions[id]?.notices = inbox.entries.isEmpty ? nil : inbox.entries
            } catch { saveError = "알림 배지를 저장하지 못했습니다. \(error.localizedDescription)" }
        }
        if snapshot.health.noticeError != saveError { snapshot.health.noticeError = saveError }
    }

    public func refresh() async {
        guard !discovering else { return }
        discovering = true
        defer { discovering = false; initialDiscoveryComplete = true }
        do {
            let reader = processReader
            let discovered = try await Task.detached(priority: .utility) { try reader() }.value
            let found = ProcessDiscovery.sessions(discovered)
            let directories = await Task.detached(priority: .utility) {
                let paths = ProcessDiscovery.workingDirectories(pids: found.map(\.pid))
                return Dictionary(found.compactMap { session in paths[session.pid].map { (session.id, $0) } }, uniquingKeysWith: { a, _ in a })
            }.value
            updateDiscovery(found, records: discovered, directories: directories)
            snapshot.health.discoveryError = nil
        } catch { snapshot.health.discoveryError = error.localizedDescription }
        refreshGitBranches()
        let codexTargets = Array(sessions.values).filter { $0.agent == .codex && $0.phase != .ended }
        async let questions = codexQuestions.collect(codexTargets)
        await refreshTerminal()
        updateCodexQuestions(await questions)
        publish()
    }

    private func refreshGitBranches() {
        guard gitBranchTask == nil else { return }
        let targets = Array(sessions.values)
        gitBranchTask = Task { [weak self] in
            let updates = await GitBranchReader.collect(targets)
            guard !Task.isCancelled, let self else { return }
            self.updateGitBranches(updates)
            self.gitBranchTask = nil
        }
    }

    public func updateGitBranches(_ updates: [GitBranchUpdate]) {
        var changed = false
        for update in updates {
            guard let session = sessions[update.sessionID], session.agent != .shell,
                  session.phase != .ended, session.cwd == update.cwd,
                  session.gitBranch != update.state else { continue }
            sessions[session.id]?.gitBranch = update.state
            changed = true
        }
        if changed { publish() }
    }

    public func updateCodexQuestions(_ updates: [CodexQuestionUpdate], at date: Date = Date()) {
        for update in updates {
            guard var session = sessions[update.sessionID], session.agent == .codex, session.phase != .ended else { continue }
            session.codexQuestionsError = update.error
            session.completionError = update.completionError ?? (update.turn == nil && !update.completionReadPending ? update.error : nil)
            if let turn = update.turn {
                let completed = codexCompletions.observe(turn, sessionID: session.id, at: date)
                if turn.status != "completed" || session.completion?.id != "codex:\(turn.threadID):\(turn.turnID ?? "")" {
                    session.completion = nil
                }
                if let completed { session.completion = completed }
            } else if update.completionReadPending || update.error != nil || update.completionError != nil {
                session.completion = nil
            }
            if update.error == nil, let questions = update.questions {
                let threadID = update.threadID ?? update.turn?.threadID ?? questions.first?.threadID
                    ?? questionThreadBySession[session.id] ?? session.id
                if questionThreadBySession[session.id] != threadID {
                    restoredQuestionIDs.formUnion(questions.map(\.id))
                    questionThreadBySession[session.id] = threadID
                }
                session.queuedQuestions = questions.filter { store.value("dismissedQuestion:\($0.id)") != "true" }.map { question in
                    var question = question
                    if questionAutomationOverrides[question.id] == nil,
                       let saved = store.value("questionAutomation:\(question.id)"),
                       let phase = QuestionAutomation.Phase(rawValue: saved), [.editing, .cancelled].contains(phase) {
                        questionAutomationOverrides[question.id] = phase
                    }
                    if let previous = session.questions.first(where: { $0.id == question.id }) {
                        question.reply = previous.isSameRequest(as: question) ? previous.reply : nil
                    } else {
                        question.reply = savedReply(question.id)
                    }
                    return question
                }
                session.codexQuestionsObservedAt = date
                readableQuestionSessions.insert(session.id)
            } else {
                readableQuestionSessions.remove(session.id)
            }
            sessions[session.id] = session
        }
        publish()
    }

    public func dismissQuestion(sessionID: String, questionID: String) throws {
        guard let session = sessions[sessionID], session.phase != .ended,
              session.questions.contains(where: { $0.id == questionID }) else { return }
        try store.set("dismissedQuestion:\(questionID)", "true")
        sessions[sessionID]?.queuedQuestions?.removeAll { $0.id == questionID }
        publish()
    }

    private func savedReply(_ questionID: String) -> QuestionReply? {
        guard let json = store.value("questionReply:\(questionID)"),
              var reply = try? JSONDecoder().decode(QuestionReply.self, from: Data(json.utf8)) else { return nil }
        if reply.phase == .sending && !replyingQuestions.contains(questionID) {
            reply.phase = .uncertain
            reply.message = "이전 전송의 접수 결과를 확인하지 못했습니다. 터미널에서 확인해주세요."
        }
        return reply
    }

    private func setReply(_ reply: QuestionReply, sessionID: String, question: QueuedQuestion, persist: Bool) throws {
        guard let index = sessions[sessionID]?.queuedQuestions?.firstIndex(where: { $0.isSameRequest(as: question) }) else { return }
        if persist {
            try store.set("questionReply:\(question.id)", String(decoding: JSONEncoder().encode(reply), as: UTF8.self))
        }
        sessions[sessionID]?.queuedQuestions?[index].reply = reply
        publish()
    }

    private func cancelAutomaticQuestionReply(_ questionID: String) {
        automaticQuestionReplies.removeValue(forKey: questionID)?.task.cancel()
    }

    public func beginQuestionReply(sessionID: String, questionID: String) throws {
        try holdQuestionAutomaticReply(sessionID: sessionID, questionID: questionID, phase: .editing)
    }

    public func cancelQuestionAutomaticReply(sessionID: String, questionID: String) throws {
        try holdQuestionAutomaticReply(sessionID: sessionID, questionID: questionID, phase: .cancelled)
    }

    private func holdQuestionAutomaticReply(sessionID: String, questionID: String, phase: QuestionAutomation.Phase) throws {
        guard let session = sessions[sessionID], session.phase != .ended,
              session.questions.contains(where: { $0.id == questionID }),
              questionAutomationOverrides[questionID] == nil else { return }
        // Stop the timer synchronously with the edit, even if saving fails.
        questionAutomationOverrides[questionID] = phase
        cancelAutomaticQuestionReply(questionID)
        publish()
        try store.set("questionAutomation:\(questionID)", phase.rawValue)
    }

    private func questionAutomationBlock(_ question: QueuedQuestion, in session: AgentSession) -> QuestionAutomation.Phase? {
        if let override = questionAutomationOverrides[question.id] { return override }
        if session.questions.filter({ $0.threadID == question.threadID && $0.titleIdentity == question.titleIdentity }).count > 1 { return .duplicate }
        if question.hasLaterUserMessage == true { return .needsReview }
        if restoredQuestionIDs.contains(question.id) { return .restored }
        return nil
    }

    private func updateQuestionAutomationStates() {
        for (id, session) in sessions {
            guard let questions = session.queuedQuestions else { continue }
            sessions[id]?.queuedQuestions = questions.map { question in
                var question = question
                question.automation = nil
                guard session.phase != .ended, question.reply == nil || question.reply?.phase == .cancelled else { return question }
                if let block = questionAutomationBlock(question, in: session) {
                    question.automation = QuestionAutomation(phase: block)
                } else if let confirmation = YesNoConfirmation.detect(question), session.automatic {
                    if snapshot.paused {
                        question.automation = QuestionAutomation(phase: .paused, answer: confirmation.answer)
                    } else if let pending = automaticQuestionReplies[question.id] {
                        question.automation = QuestionAutomation(phase: .scheduled, deadline: pending.deadline, answer: confirmation.answer)
                    } else if !session.canApprove || session.codexQuestionsError != nil || !readableQuestionSessions.contains(id) {
                        question.automation = QuestionAutomation(phase: .unavailable, answer: confirmation.answer)
                    }
                }
                return question
            }
        }
    }

    private func reconcileAutomaticQuestionReplies() {
        var candidates: [String: (sessionID: String, question: QueuedQuestion, answer: String)] = [:]
        if !questionAutomationStopped, !snapshot.paused {
            for session in sessions.values where session.agent == .codex && session.automatic && session.canApprove
                && session.codexQuestionsError == nil && readableQuestionSessions.contains(session.id) {
                for var question in session.questions {
                    let pending = automaticQuestionReplies[question.id]
                    // Keep our reservation during preflight, but never automatically retry
                    // a failed, uncertain, queued, or manually submitted response.
                    guard questionAutomationBlock(question, in: session) == nil,
                          question.reply == nil || question.reply?.phase == .cancelled || (question.reply?.phase == .sending && pending?.sending == true),
                          let confirmation = YesNoConfirmation.detect(question) else { continue }
                    question.reply = nil; question.automation = nil
                    candidates[question.id] = (session.id, question, confirmation.answer)
                }
            }
        }
        for (id, pending) in automaticQuestionReplies {
            guard let candidate = candidates[id], candidate.sessionID == pending.sessionID,
                  candidate.question.isSameRequest(as: pending.question) else {
                cancelAutomaticQuestionReply(id)
                continue
            }
        }
        for (id, candidate) in candidates where automaticQuestionReplies[id] == nil && !replyingQuestions.contains(id) {
            let token = UUID()
            let deadline = Date().addingTimeInterval(5)
            let task = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
                guard let self, self.automaticQuestionReplies[id]?.token == token else { return }
                self.automaticQuestionReplies[id]?.sending = true
                defer {
                    if self.automaticQuestionReplies[id]?.token == token {
                        self.automaticQuestionReplies.removeValue(forKey: id)
                    }
                    self.publish()
                }
                // The shared reply path publishes failures and reserves every dispatch.
                try? await self.sendQuestionReply(sessionID: candidate.sessionID, questionID: id,
                    answer: candidate.answer, automaticToken: token)
            }
            automaticQuestionReplies[id] = AutomaticQuestionReply(token: token, sessionID: candidate.sessionID,
                question: candidate.question, deadline: deadline, task: task)
        }
    }

    /// Manual replies remain available while automatic approval is paused.
    public func replyToQuestion(sessionID: String, questionID: String, answer: String) async throws {
        if automaticQuestionReplies[questionID]?.sessionID == sessionID {
            cancelAutomaticQuestionReply(questionID)
        }
        try await sendQuestionReply(sessionID: sessionID, questionID: questionID, answer: answer)
    }

    /// Queuing acknowledges receipt, not delivery to the running turn.
    /// Uncertain submissions are not retried, including after an app restart.
    private func sendQuestionReply(sessionID: String, questionID: String, answer: String, automaticToken: UUID? = nil) async throws {
        guard let session = sessions[sessionID], session.agent == .codex, session.phase != .ended,
              let question = session.questions.first(where: { $0.id == questionID }),
              question.reply == nil || question.reply?.canRetry == true,
              replyingQuestions.insert(questionID).inserted else {
            throw AppError.message("이미 전송 중이거나 처리한 질문입니다. 현재 상태를 확인해주세요.")
        }
        defer {
            replyingQuestions.remove(questionID)
            publish()
        }
        let answer = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        let sending = QuestionReply(phase: .sending, answer: answer, message: "Codex 응답 경로를 확인하고 있습니다…")
        var launched = false
        var audit: AuditEvent?
        do {
            let message = try CodexReplyTransport.message(question: question, answer: answer)
            try setReply(sending, sessionID: sessionID, question: question, persist: false)
            let target = try await questionTransport.prepare(session, question)
            guard target.threadID == question.threadID, let current = sessions[sessionID], current.phase != .ended,
                  current.questions.contains(where: { $0.isSameRequest(as: question) }) else {
                throw AppError.message("세션이나 질문이 바뀌었습니다. 목록을 새로고침해주세요.")
            }
            if let automaticToken {
                guard !Task.isCancelled, !snapshot.paused, current.automatic, current.canApprove,
                      automaticQuestionReplies[questionID]?.token == automaticToken else {
                    throw AppError.message("자동 응답이 취소되었습니다. 필요하면 직접 답변을 보내주세요.")
                }
                if let reason = target.automaticReplyUnavailableReason { throw AppError.message(reason) }
            }
            let event = AuditEvent(sessionID: sessionID, summary: question.summary, outcome: "답변 전송 준비",
                source: automaticToken == nil ? "Codex 질문 응답" : "Codex 질문 자동 응답", context: AuditContext(session: session),
                tool: "request_user_input_async", request: question.summary, answer: answer)
            guard log(event, session: session) else { throw AppError.message("답변 내역을 저장하지 못해 전송하지 않았습니다.") }
            audit = event
            // A crash after this reservation requires verification, never an automatic resend.
            try setReply(sending, sessionID: sessionID, question: question, persist: true)
            launched = true
            let queueID = try await questionTransport.send(target, message)
            let reply = QuestionReply(phase: .queued, answer: answer,
                message: "답변을 Codex 대기열에 넣었습니다. Codex가 받을 차례가 되면 전달됩니다.", queueID: queueID)
            do { try setReply(reply, sessionID: sessionID, question: question, persist: true) }
            catch {
                snapshot.health.auditError = error.localizedDescription
                try setReply(reply, sessionID: sessionID, question: question, persist: false)
            }
            audit?.outcome = "답변 대기열 등록"
            if let audit { log(audit, session: session) }
        } catch {
            let cancelled = automaticToken.map { !launched && (Task.isCancelled || automaticQuestionReplies[questionID]?.token != $0) } ?? false
            let reply = QuestionReply(phase: cancelled ? .cancelled : (launched ? .uncertain : .failed), answer: answer,
                message: cancelled ? "전송 전에 자동 응답을 멈췄습니다." : error.localizedDescription)
            do { try setReply(reply, sessionID: sessionID, question: question, persist: true) }
            catch { try? setReply(reply, sessionID: sessionID, question: question, persist: false) }
            audit?.outcome = launched ? "답변 접수 확인 필요" : "답변 전송 전 중단"
            if let audit { log(audit, session: session) }
            throw error
        }
    }

    public func updateDiscovery(_ found: [AgentSession], records: [ProcessRecord], directories: [String: String] = [:], claudeRegistrations: [ClaudeSessionRegistration]? = nil) {
        self.records = records
        // Ordinary terminals do not belong in the inventory or its status counts.
        let managed = found.filter { $0.agent == .claude || $0.agent == .codex }
        let live = Set(managed.map(\.id))
        codexCompletions.retain(sessionIDs: live)
        for var session in managed {
            if var existing = sessions[session.id] {
                existing.tty = session.tty
                if existing.bridgeID == nil { existing.terminal = session.terminal }
                session = existing
            }
            if let cwd = directories[session.id], !cwd.isEmpty, session.cwd != cwd {
                session.cwd = cwd; session.gitBranch = nil
            }
            if session.phase == .ended { session.setPhase(.unknown, detail: "새 상태를 확인하고 있습니다."); session.channel = .none; session.automatic = false }
            if sessions[session.id] == nil {
                restorePreferences(&session)
                session.detail = session.terminal == .vscode ? "VS Code 확장을 연결하세요. 이미 실행 중인 Claude는 훅으로도 연결할 수 있습니다." : "연결 설정에서 Terminal 연결 또는 Claude 훅을 설정하세요."
            }
            sessions[session.id] = session
        }
        for key in Array(sessions.keys) where key.hasPrefix("process:") && !live.contains(key) {
            sessions[key]?.setPhase(.ended, detail: "프로세스가 종료되었습니다."); sessions[key]?.channel = .none; sessions[key]?.automatic = false
            sessions[key]?.queuedQuestions = []; sessions[key]?.codexQuestionsError = nil
            claudeWorkIDs.removeValue(forKey: key)
            clearScreen(key)
        }
        let registrations = claudeRegistrations ?? claudeRegistryReader(records)
        reconcileClaudeParents(registrations: registrations)
        reconcileClaudeActivities(registrations)
        for (bridge, terminals) in bridges { matchBridge(bridge, terminals: terminals) }
        for (id, observed) in screenObservedAt where Date().timeIntervalSince(observed) > 10 {
            if sessions[id]?.channel != .hook {
                sessions[id]?.setPhase(.unknown, detail: "새 화면을 받지 못해 현재 상태를 확인할 수 없습니다.")
                screens.removeValue(forKey: id); activityTrackers.removeValue(forKey: id)
            }
        }
        publish()
    }

    public func setAutomatic(_ id: String, enabled: Bool) throws {
        let target = ownerID(id) ?? id
        guard var session = sessions[target], presentedSessions().first(where: { $0.id == target })?.canApprove == true || !enabled else { throw AppError.message("이 세션의 승인 연결을 먼저 설정해주세요.") }
        var nextParents = claudeParents
        // Explicit control of an orphan starts a new, independent opt-in.
        if ownerID(id) == nil { nextParents.removeValue(forKey: id) }
        try store.setValues(["automatic:\(target)": enabled ? "true" : "false", "claudeParents": String(decoding: try JSONEncoder().encode(nextParents), as: UTF8.self)])
        claudeParents = nextParents
        session.automatic = enabled; sessions[target] = session
        for member in groupIDs(target) { screens[member]?.scheduledID = nil }
        publish()
        if enabled { scheduleScreenApproval(target) }
    }
    public func setPaused(_ paused: Bool) throws {
        snapshot.paused = paused; revision &+= 1
        for id in screens.keys { screens[id]?.scheduledID = nil }
        try store.set("paused", paused ? "true" : "false")
        if !paused { for id in screens.keys { scheduleScreenApproval(id) } }
        publish()
    }
    public func connectTerminal() async {
        do { try store.set("terminalEnabled", "true") }
        catch { snapshot.health.terminal = "연결 설정 저장 실패: \(error.localizedDescription)"; return }
        terminalEnabled = true; terminalPermissionBlocked = false; terminalRetryAfter = .distantPast
        snapshot.health.terminalRequested = true; snapshot.health.terminal = "연결 확인 중…"
        await refreshTerminal(); publish()
    }
    public func disconnectTerminal() {
        terminalEnabled = false; revision &+= 1; snapshot.health.terminal = "연결 해제됨"
        snapshot.health.terminalRequested = false; snapshot.health.terminalConnected = false
        do { try store.set("terminalEnabled", "false") }
        catch { snapshot.health.terminal = "연결은 해제했지만 설정을 저장하지 못했습니다: \(error.localizedDescription)" }
        for id in Array(sessions.keys) where sessions[id]?.channel == .terminalScreen {
            sessions[id]?.channel = .none; sessions[id]?.setPhase(.unknown, detail: "Terminal 연결이 해제되어 현재 상태를 확인할 수 없습니다."); clearScreen(id)
        }
        publish()
    }
    public func refreshTerminal() async {
        guard terminalEnabled, !terminalPolling, !terminalPermissionBlocked, Date() >= terminalRetryAfter else { return }
        terminalPolling = true; snapshot.health.terminalConnecting = true
        defer { terminalPolling = false; snapshot.health.terminalConnecting = false }
        let targets = sessions.values.filter { $0.agent != .shell && $0.terminal == .terminal && $0.phase != .ended }
        do {
            let ttys = targets.map(\.tty)
            let reader = terminalReader
            let result = try await Task.detached(priority: .utility) { try reader(ttys) }.value
            guard terminalEnabled else { return }
            let connected = targets.filter { target in result.screens.contains { $0.tty == target.tty } }.count
            let missing = targets.count - connected
            snapshot.health.terminalConnected = connected > 0 || targets.isEmpty
            if connected > 0 {
                snapshot.health.terminal = "연결됨 · \(connected)개 세션" + (missing > 0 ? " · \(missing)개 탭 확인 필요" : "")
            } else if targets.isEmpty {
                snapshot.health.terminal = "연결됨 · Terminal에서 실행 중인 CLI 세션 없음"
            } else {
                snapshot.health.terminal = "해당 세션의 Terminal 탭을 읽지 못했습니다. " + (result.failures.first?.message ?? "닫힌 탭인지 확인한 후 다시 연결해주세요.")
            }
            for target in targets {
                guard let screen = result.screens.first(where: { $0.tty == target.tty }) else {
                    if sessions[target.id]?.channel != .hook {
                        sessions[target.id]?.channel = .none
                        sessions[target.id]?.setPhase(.unknown, detail: "현재 Terminal 화면을 읽지 못했습니다.")
                        sessions[target.id]?.pendingSummary = nil
                        sessions[target.id]?.detail = "이 세션의 Terminal 탭을 읽지 못했습니다. " + (result.failures.first(where: { $0.tty == target.tty })?.message ?? "탭이 열려 있는지 확인해주세요.")
                        clearScreen(target.id)
                    }
                    continue
                }
                sessions[target.id]?.terminalTitle = screen.title
                if sessions[target.id]?.channel != .hook || sessions[target.id]?.pendingInTerminal == true {
                    if sessions[target.id]?.channel != .hook { sessions[target.id]?.channel = .terminalScreen }
                    sessions[target.id]?.detail = "화면의 실행 권한 확인을 감지합니다. 일반 질문은 직접 답해주세요."
                    receiveScreen(sessionID: target.id, raw: screen.contents, generation: "terminal:\(target.id)", source: .terminalScreen)
                }
            }
        } catch {
            snapshot.health.terminalConnected = false
            terminalPermissionBlocked = (error as? TerminalAdapterError) == .permissionDenied
            terminalRetryAfter = Date().addingTimeInterval(5)
            snapshot.health.terminal = error.localizedDescription + (terminalPermissionBlocked ? "" : " · 자동 재연결 대기")
            for id in Array(sessions.keys) where sessions[id]?.channel == .terminalScreen {
                sessions[id]?.channel = .none; sessions[id]?.setPhase(.unknown, detail: "Terminal 연결이 끊겨 현재 상태를 확인할 수 없습니다."); clearScreen(id)
            }
        }
    }

    public func reveal(_ session: AgentSession) async throws -> TerminalWindowBounds? {
        let live = try await Task.detached { try ProcessDiscovery.read() }.value
        guard let current = sessions[session.id], current.canReveal, current.pid == session.pid,
              current.started == session.started, current.tty == session.tty,
              live.contains(where: { $0.pid == session.pid && $0.started == session.started && $0.agent == session.agent
                  && "/dev/" + $0.tty == session.tty }) else {
            throw AppError.message("이 세션이 종료되었거나 터미널이 바뀌었습니다. 목록을 새로고침해주세요.")
        }
        if current.terminal == .terminal {
            return try await Task.detached { try TerminalAdapter.reveal(tty: current.tty) }.value
        } else if let peerID = current.bridgeID, let terminalID = current.terminalID, let peer = peers[peerID] {
            guard peer.send(["method": "reveal", "terminalID": terminalID, "id": UUID().uuidString, "label": session.project, "detail": "\(session.agent.title) · \(session.tty)"]) else { throw AppError.message("VS Code 연결이 끊겼습니다.") }
            return nil
        } else { throw AppError.message("연결 설정에서 해당 터미널을 먼저 연결해주세요.") }
    }

    public func installClaude(executable: String) throws {
        _ = try HookInstaller.install(executable: executable, home: paths.directory.path)
        snapshot.health.claude = "설치됨 · 다음 세션 이벤트 대기"
    }
    public func upgradeClaudeHooks(executable: String) {
        do { try HookInstaller.upgradeTimeouts(executable: executable) }
        catch { snapshot.health.claude = "훅 응답 대기 설정을 갱신하지 못했습니다. 연결 설정에서 Claude 훅을 다시 설치해주세요." }
    }
    public func removeClaude(settingsURL: URL = HookInstaller.settingsURL) throws {
        let targets = sessions.values.filter { $0.channel == .hook }.map(\.id)
        // Disconnecting also turns these sessions off. Persist that decision before
        // removing the hooks so a restart cannot revive an old enabled preference.
        for id in targets { try setAutomatic(id, enabled: false) }
        for pending in Array(liveClaudeHooks.values) where pending.receipt.response == nil {
            try releaseClaudeApproval(sessionID: pending.request.sessionID, requestID: pending.request.id)
        }
        _ = try HookInstaller.install(executable: nil, url: settingsURL)
        snapshot.health.claude = "훅 연결 해제됨"
        for id in targets {
            sessions[id]?.channel = .none; sessions[id]?.automatic = false
            sessions[id]?.setPhase(.unknown, detail: "Claude 훅 연결이 해제되었습니다.")
        }
        publish()
    }

    public func auditHistory(search: String = "", result: AuditResult? = nil, through: Date = Date(), offset: Int = 0) async throws -> AuditPage {
        let path = paths.database
        return try await Task.detached(priority: .utility) {
            try AuditStore(path: path, readOnly: true).history(search: search, result: result, through: through, offset: offset)
        }.value
    }

    private func contextualEvent(_ event: AuditEvent, session: AgentSession? = nil) -> AuditEvent {
        var event = event
        if event.context == nil, let current = session ?? sessions[event.sessionID] { event.context = AuditContext(session: current) }
        if let parent = ownerID(event.sessionID), parent != event.sessionID {
            event.originSessionID = event.sessionID
            event.sessionID = parent
            if event.source == "Claude 훅" { event.source = "Claude 백그라운드 훅" }
        }
        return event
    }

    @discardableResult private func log(_ event: AuditEvent, session: AgentSession? = nil) -> Bool {
        let event = contextualEvent(event, session: session)
        do { try store.append(event); snapshot.health.auditError = nil }
        catch { snapshot.health.auditError = error.localizedDescription; return false }
        if let index = snapshot.events.firstIndex(where: { $0.id == event.id }) { snapshot.events[index] = event }
        else { snapshot.events.insert(event, at: 0) }
        if snapshot.events.count > 200 { snapshot.events.removeLast(snapshot.events.count - 200) }
        return true
    }

    /// Legacy helpers pass unanswered requests back to Claude. New helpers use the durable bridge below.
    public func handleHook(_ payload: JSONObject, deferApproval: Bool = false) -> JSONObject {
        guard let event = payload["hook_event_name"] as? String,
              let providerID = payload["session_id"] as? String, !providerID.isEmpty,
              let requestID = payload["requestID"] as? String else { return [:] }
        let pid = (payload["agentPID"] as? NSNumber)?.int32Value ?? 0
        let started = payload["agentStarted"] as? String ?? ""
        let key = pid > 0 && !started.isEmpty ? "process:\(pid):\(started)" : "claude:\(providerID)"
        // A new child may call its hook before the polling loop has discovered it.
        var lineageVerified = true
        if pid > 0, !records.contains(where: { $0.key == key }) || claudeParents[key] != nil || sessions[key]?.terminal == .claudeBackground {
            if let current = try? processReader(), current.contains(where: { $0.key == key }) {
                updateDiscovery(ProcessDiscovery.sessions(current), records: current)
            } else if claudeParents[key] != nil { lineageVerified = false }
        } else {
            reconcileClaudeParents(registrations: claudeRegistryReader(records))
        }
        var session = sessions[key] ?? AgentSession(id: key, agent: .claude, pid: pid, started: started, tty: payload["tty"] as? String ?? "", cwd: payload["cwd"] as? String ?? "", terminal: .unknown)
        guard session.agent == .claude else { return [:] }
        if event != "Notification" {
            claudeHookObservedAt[key] = Date()
            recoveredClaudeStates.remove(key)
        }
        // Hooks can arrive before the first process scan after an app restart.
        if sessions[key] == nil { restorePreferences(&session) }
        if let cwd = payload["cwd"] as? String, !cwd.isEmpty, session.cwd != cwd {
            session.cwd = cwd; session.gitBranch = nil
        }
        session.providerID = providerID; session.lastActivity = Date()
        // A hook owns this session now; any queued screen approval is obsolete.
        clearScreen(key)
        session.channel = event == "SessionEnd" ? .none : .hook
        session.detail = "Claude의 권한 요청을 직접 받습니다. 네트워크 확인 등 일부 요청은 터미널에서 처리합니다."
        if !lineageVerified { session.detail = "메인 세션의 실행 상태를 확인하지 못해 백그라운드 자동 승인을 멈췄습니다." }
        let tool = payload["tool_name"] as? String ?? ""
        let input = payload["tool_input"] as? JSONObject ?? [:]
        let summary = QuestionDetector.hookSummary(tool: tool, input: input, message: payload["message"] as? String)
        let request = (try? JSONSerialization.data(withJSONObject: input, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])).map { String(decoding: $0, as: UTF8.self) }
        let needsAnswer = ["AskUserQuestion", "ExitPlanMode", "EnterPlanMode"].contains(tool)
        if ["UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest"].contains(event) {
            if event == "UserPromptSubmit" || claudeWorkIDs[key] == nil { claudeWorkIDs[key] = UUID().uuidString }
            session.completion = nil
        } else if event == "SessionStart" || event == "SessionEnd" {
            claudeWorkIDs.removeValue(forKey: key); session.completion = nil
        }
        var response: JSONObject = [:]
        if tool == "AskUserQuestion", ["PreToolUse", "PermissionRequest"].contains(event),
           let confirmation = YesNoConfirmation.detect(input) {
            // tool_use_id joins PreToolUse and PermissionRequest for one logical question.
            let toolID = (payload["tool_use_id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? requestID
            let first = rememberHook(key + ":question:" + providerID + ":" + toolID)
            if first {
                session.setPhase(.input, detail: "Claude가 예·아니오 확인을 기다리고 있습니다.")
                session.pendingSummary = summary; session.pendingInTerminal = true
                session.pendingRequestID = "hook:\(providerID):\(toolID)"
                if !deferApproval, lineageVerified, effectiveAutomatic(key, fallback: session), !snapshot.paused {
                    let audit = AuditEvent(sessionID: key, summary: summary, outcome: "질문 응답 전달", source: "Claude 훅",
                        tool: tool, request: request, answer: confirmation.answer)
                    if log(audit, session: session) {
                        let updated = confirmation.updatedInput(input)
                        if event == "PreToolUse" {
                            response = ["hookSpecificOutput": ["hookEventName": event, "permissionDecision": "allow", "updatedInput": updated]]
                        } else {
                            response = ["hookSpecificOutput": ["hookEventName": event, "decision": ["behavior": "allow", "updatedInput": updated]]]
                        }
                        session.setPhase(.working, detail: "예·아니오 확인에 ‘\(confirmation.answer)’ 응답을 전달했습니다.")
                        session.pendingSummary = nil; session.pendingInTerminal = false
                        session.pendingRequestID = nil
                    } else {
                        session.activityDetail = "응답 내역을 저장하지 못했습니다. 터미널에서 질문에 답해주세요."
                    }
                } else if !deferApproval {
                    session.activityDetail = snapshot.paused
                        ? "전체 자동 승인이 일시정지되어 ‘예’로 응답하지 않았습니다. 현재 질문은 원래 세션에서 답해주세요."
                        : "이 세션의 자동 승인이 꺼져 있어 ‘예’로 응답하지 않았습니다. 켜면 다음 예·아니오 질문부터 응답합니다."
                    log(AuditEvent(sessionID: key, summary: summary, outcome: "터미널에서 확인", source: "Claude 훅", tool: tool, request: request), session: session)
                }
            }
            sessions[key] = session; snapshot.health.claude = "연결됨 · 세션 이벤트 수신 중"; publish()
            return response
        }
        switch event {
        case "SessionStart": session.setPhase(.unknown, detail: "Claude 세션을 연결했습니다. 다음 작업 이벤트를 기다리고 있습니다."); session.pendingSummary = nil; session.pendingInTerminal = false
        case "PermissionRequest":
            session.setPhase(needsAnswer ? .input : .approval, detail: needsAnswer ? "Claude가 질문에 대한 응답을 기다리고 있습니다." : "Claude가 실행 권한에 대한 응답을 기다리고 있습니다."); session.pendingSummary = summary; session.pendingInTerminal = true
            let fingerprint = key + ":" + requestID
            let first = rememberHook(fingerprint)
            if !deferApproval, lineageVerified, effectiveAutomatic(key, fallback: session), !snapshot.paused, first, !needsAnswer {
                response = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": ["behavior": "allow"]]]
                session.setPhase(.working, detail: "권한을 승인해 작업을 계속합니다."); session.pendingSummary = nil; session.pendingInTerminal = false
                if !log(AuditEvent(sessionID: key, summary: summary, outcome: "승인 전달", source: "Claude 훅", tool: tool, request: request), session: session) {
                    response = [:]
                    session.setPhase(.approval, detail: "승인 내역을 저장하지 못했습니다. 터미널에서 요청을 확인해주세요.")
                    session.pendingSummary = summary; session.pendingInTerminal = true
                }
            } else if first && !deferApproval {
                log(AuditEvent(sessionID: key, summary: summary, outcome: "터미널에서 확인", source: "Claude 훅", tool: tool, request: request), session: session)
            }
        case "SessionEnd": session.setPhase(.ended, detail: "Claude 세션 종료 이벤트를 받았습니다."); session.automatic = false; session.pendingSummary = nil; session.pendingInTerminal = false
        case "Stop":
            guard !session.pendingInTerminal else { break }
            let background = payload["background_tasks"] as? [Any] ?? []
            let scheduled = payload["session_crons"] as? [Any] ?? []
            if !background.isEmpty || !scheduled.isEmpty {
                session.completion = nil
                session.setPhase(.idle, detail: "Claude 응답은 끝났고 다음 지시를 받을 수 있습니다. 백그라운드 작업 또는 예약된 후속 작업을 모니터링 중입니다.", monitoring: true)
                session.pendingSummary = nil
            } else {
                if let workID = claudeWorkIDs.removeValue(forKey: key) ?? (session.phase == .working ? UUID().uuidString : nil) {
                    session.completion = WorkCompletion(id: "claude:\(providerID):\(workID)", summary: payload["last_assistant_message"] as? String)
                }
                session.setPhase(.idle, detail: "Claude의 응답 완료 이벤트를 받았습니다. 다음 지시를 기다리고 있습니다.", monitoring: false); session.pendingSummary = nil
            }
        case "Notification":
            let type = payload["notification_type"] as? String ?? ""
            // Generic reminders must not erase the actual question and its choices.
            if type == "permission_prompt", !(session.phase == .input && session.pendingInTerminal) { session.setPhase(.approval, detail: "Claude가 실행 권한에 대한 응답을 기다리고 있습니다."); session.pendingInTerminal = true; if session.pendingSummary == nil, !summary.isEmpty { session.pendingSummary = summary } }
            else if type == "idle_prompt", !session.pendingInTerminal { session.setPhase(.idle, detail: session.backgroundMonitoring == true ? "Claude는 다음 지시를 기다리며 백그라운드 작업을 모니터링하고 있습니다." : "Claude의 입력 대기 알림을 받았습니다."); session.pendingSummary = nil }
            else if type == "elicitation_dialog" { session.setPhase(.input, detail: "Claude가 질문에 대한 응답을 기다리고 있습니다."); session.pendingSummary = summary; session.pendingInTerminal = true }
        case "PreToolUse":
            session.setPhase(needsAnswer ? .input : .working, detail: needsAnswer ? "Claude가 질문에 대한 응답을 기다리고 있습니다." : "Claude의 도구 실행 이벤트를 받았습니다.")
            session.pendingSummary = needsAnswer ? summary : nil; session.pendingInTerminal = needsAnswer
        case "UserPromptSubmit", "PostToolUse": session.setPhase(.working, detail: "Claude가 요청을 처리하고 있습니다."); session.pendingSummary = nil; session.pendingInTerminal = false
        default: break
        }
        if session.pendingSummary == nil {
            session.pendingRequestID = nil
        } else if ["PreToolUse", "PermissionRequest"].contains(event) {
            if let toolID = payload["tool_use_id"] as? String, !toolID.isEmpty {
                session.pendingRequestID = "hook:\(providerID):\(toolID)"
            } else if event == "PreToolUse" || session.pendingRequestID == nil {
                session.pendingRequestID = "hook:\(providerID):\(requestID)"
            }
        }
        sessions[key] = session; snapshot.health.claude = "연결됨 · 세션 이벤트 수신 중"; publish()
        return response
    }

    private func rememberHook(_ fingerprint: String) -> Bool {
        guard handledHookIDs.insert(fingerprint).inserted else { return false }
        hookIDOrder.append(fingerprint)
        if hookIDOrder.count > 4096 { handledHookIDs.remove(hookIDOrder.removeFirst()) }
        return true
    }

    private func bridgeResponse(_ response: JSONObject? = nil) -> JSONObject {
        if let response { return ["autoapproveBridge": ["response": response]] }
        return ["autoapproveBridge": ["waiting": true]]
    }

    private func saveClaudeReceipt(_ receipt: ClaudeHookReceipt) throws {
        do {
            try store.saveClaudeHook(receipt)
            snapshot.health.auditError = nil
            if receipt.audit != nil { snapshot.events = store.recent() }
        } catch { snapshot.health.auditError = error.localizedDescription; throw error }
    }

    /// Polls carry the original UUID and full input, so a restarted app can resume the exact hook.
    public func handleClaudeHook(_ payload: JSONObject, at now: Date = Date()) throws -> JSONObject {
        guard let request = ClaudeHookRequest(payload, at: now) else { return bridgeResponse([:]) }
        var receipt: ClaudeHookReceipt
        if let saved = try store.claudeHook(id: request.id) {
            guard saved.fingerprint == request.fingerprint else { throw AppError.message("같은 요청 ID의 내용이 달라 응답하지 않았습니다.") }
            receipt = saved
            if let response = saved.response {
                removeLiveClaudeHook(request.id)
                publish()
                return bridgeResponse((try JSONSerialization.jsonObject(with: Data(response.utf8))) as? JSONObject ?? [:])
            }
        } else {
            receipt = ClaudeHookReceipt(id: request.id, fingerprint: request.fingerprint, sessionID: request.sessionID,
                logicalID: request.logicalID, createdAt: now, expiresAt: request.expiresAt)
            if let logicalID = request.logicalID, let previous = try store.claudeHook(logicalID: logicalID), previous.expiresAt > now {
                // PreToolUse -> PermissionRequest is the same tool call, not another approval.
                receipt.response = "{}"
                try saveClaudeReceipt(receipt)
                return bridgeResponse([:])
            }
        }
        if request.response == nil {
            invalidateClaudeHooks(for: payload, sessionID: request.sessionID)
            let response = handleHook(payload)
            receipt.response = String(decoding: try JSONSerialization.data(withJSONObject: response), as: UTF8.self)
            try saveClaudeReceipt(receipt)
            return bridgeResponse(response)
        }
        if liveClaudeHooks[request.id] == nil {
            _ = handleHook(payload, deferApproval: true)
            // Never offer a button for a guessed process or an already-ended session.
            guard sessions[request.sessionID]?.phase != .ended,
                  records.contains(where: { $0.key == request.sessionID && $0.agent == .claude }) else {
                receipt.response = "{}"; try saveClaudeReceipt(receipt)
                return bridgeResponse([:])
            }
            try saveClaudeReceipt(receipt)
        }
        liveClaudeHooks[request.id] = LiveClaudeHook(request: request, receipt: receipt, lastContact: now)
        if now.timeIntervalSince(receipt.createdAt) >= 5, effectiveAutomatic(request.sessionID), !snapshot.paused {
            try answerClaudeApproval(sessionID: request.sessionID, requestID: request.id, automatically: true, at: now)
            if let response = liveClaudeHooks[request.id]?.receipt.response {
                removeLiveClaudeHook(request.id)
                publish()
                return bridgeResponse((try JSONSerialization.jsonObject(with: Data(response.utf8))) as? JSONObject ?? [:])
            }
        }
        publish()
        return bridgeResponse()
    }

    public func answerClaudeApproval(sessionID: String, requestID: String, enableAutomatic: Bool = false, automatically: Bool = false, at now: Date = Date()) throws {
        guard let pending = liveClaudeHooks[requestID], pending.request.sessionID == sessionID,
              pending.receipt.response == nil, pending.receipt.expiresAt > now,
              now.timeIntervalSince(pending.lastContact) < 25, let response = pending.request.response else {
            throw AppError.message("이 요청은 이미 처리되었거나 연결이 끝났습니다. 현재 요청을 확인해주세요.")
        }
        // A click cannot target a reused PID/TTY or a stale parent association.
        let current = try processReader()
        guard current.contains(where: { $0.key == sessionID && $0.agent == .claude }) else {
            throw AppError.message("질문을 보낸 Claude 실행이 종료되었습니다.")
        }
        updateDiscovery(ProcessDiscovery.sessions(current), records: current)
        guard sessions[sessionID]?.phase != .ended, liveClaudeHooks[requestID]?.receipt.response == nil else {
            throw AppError.message("요청 상태가 변경되어 응답하지 않았습니다.")
        }
        if automatically, snapshot.paused || !effectiveAutomatic(sessionID) { return }
        if enableAutomatic { try setAutomatic(sessionID, enabled: true) }
        var receipt = pending.receipt
        receipt.response = String(decoding: try JSONSerialization.data(withJSONObject: response), as: UTF8.self)
        receipt.audit = contextualEvent(AuditEvent(sessionID: sessionID, summary: pending.request.summary,
            outcome: "답변 대기열 등록", source: "Claude 훅", tool: pending.request.tool,
            request: pending.request.inputJSON, answer: pending.request.answer))
        try saveClaudeReceipt(receipt)
        liveClaudeHooks[requestID]?.receipt = receipt
        claudeHookObservedAt[sessionID] = now
        publish()
    }

    public func releaseClaudeApproval(sessionID: String, requestID: String) throws {
        guard let pending = liveClaudeHooks[requestID], pending.request.sessionID == sessionID,
              pending.receipt.response == nil else { throw AppError.message("이 요청은 이미 처리되었습니다.") }
        var receipt = pending.receipt
        receipt.response = "{}"
        receipt.audit = contextualEvent(AuditEvent(sessionID: sessionID, summary: pending.request.summary,
            outcome: "터미널에서 확인", source: "Claude 훅", tool: pending.request.tool, request: pending.request.inputJSON))
        try saveClaudeReceipt(receipt)
        removeLiveClaudeHook(requestID, terminal: true)
        publish()
    }

    public func acknowledgeClaudeHook(_ payload: JSONObject, at now: Date = Date()) throws {
        guard let request = ClaudeHookRequest(payload, at: now), var receipt = try store.claudeHook(id: request.id),
              receipt.fingerprint == request.fingerprint, receipt.response != nil, !receipt.acknowledged else { return }
        receipt.acknowledged = true
        if receipt.audit?.outcome == "답변 대기열 등록" {
            receipt.audit?.outcome = request.isQuestion ? "질문 응답 전달" : "승인 전달"
        }
        try saveClaudeReceipt(receipt)
        removeLiveClaudeHook(request.id)
        publish()
    }

    private func removeLiveClaudeHook(_ id: String, terminal: Bool = false) {
        guard let pending = liveClaudeHooks.removeValue(forKey: id) else { return }
        let key = pending.request.sessionID
        if sessions[key]?.phase == .ended { return }
        if terminal {
            sessions[key]?.pendingSummary = pending.request.summary
            sessions[key]?.pendingRequestID = "hook:" + (pending.request.logicalID ?? id)
            sessions[key]?.pendingInTerminal = true
            sessions[key]?.setPhase(pending.request.isQuestion ? .input : .approval, detail: "이 요청은 터미널에서 답해주세요. 다음 지원 요청은 앱에서 처리할 수 있습니다.")
        } else if sessions[key]?.pendingRequestID == "bridge:" + id {
            sessions[key]?.pendingSummary = nil; sessions[key]?.pendingRequestID = nil; sessions[key]?.pendingInTerminal = false
            sessions[key]?.setPhase(.working, detail: "응답을 전달해 Claude 작업을 계속합니다.")
        }
    }

    private func invalidateClaudeHooks(for payload: JSONObject, sessionID: String) {
        let event = payload["hook_event_name"] as? String
        for (id, pending) in liveClaudeHooks where pending.request.sessionID == sessionID {
            let sameTool = payload["tool_use_id"] as? String != nil && payload["tool_use_id"] as? String == pending.request.payload["tool_use_id"] as? String
            guard event == "SessionEnd" || event == "UserPromptSubmit" || (event == "PostToolUse" && sameTool) else { continue }
            var receipt = pending.receipt
            if receipt.response == nil { receipt.response = "{}"; try? saveClaudeReceipt(receipt) }
            removeLiveClaudeHook(id)
        }
    }

    private func projectClaudeApprovals(at now: Date = Date()) {
        for (id, pending) in liveClaudeHooks where pending.receipt.expiresAt <= now || now.timeIntervalSince(pending.lastContact) >= 25 || sessions[pending.request.sessionID]?.phase == .ended {
            var receipt = pending.receipt
            if receipt.response == nil { receipt.response = "{}" }
            try? saveClaudeReceipt(receipt)
            removeLiveClaudeHook(id, terminal: true)
        }
        for id in Array(sessions.keys) {
            let pending = liveClaudeHooks.values.filter { $0.request.sessionID == id }.sorted { $0.receipt.createdAt < $1.receipt.createdAt }
            let automatic = effectiveAutomatic(id) && !snapshot.paused
            sessions[id]?.claudeApprovals = pending.isEmpty ? nil : pending.map { item in
                ClaudeApproval(id: item.request.id, summary: item.request.summary, answer: item.request.answer,
                    isQuestion: item.request.isQuestion, sending: item.receipt.response != nil, expiresAt: item.receipt.expiresAt,
                    automaticAt: automatic ? item.receipt.createdAt.addingTimeInterval(5) : nil)
            }
            if let first = pending.first, sessions[id]?.phase != .ended {
                sessions[id]?.pendingSummary = first.request.summary
                sessions[id]?.pendingRequestID = "bridge:" + first.request.id
                sessions[id]?.pendingInTerminal = true
                let detail = first.receipt.response != nil ? "Claude에 응답을 전달하는 중입니다…" : "AutoApprove에서 이번 요청을 허용할 수 있습니다."
                sessions[id]?.setPhase(first.request.isQuestion ? .input : .approval, detail: detail)
            }
        }
    }

    private func receive(_ message: JSONObject, from peer: SocketConnection) {
        let method = message["method"] as? String ?? ""
        let params = message["params"] as? JSONObject ?? [:]
        var result: JSONObject = [:]
        do {
            switch method {
            case "status": result = try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? JSONObject ?? [:]
            case "pause": try setPaused(params["paused"] as? Bool ?? true); result = ["paused": snapshot.paused]
            case "automatic":
                guard let id = params["sessionID"] as? String, let enabled = params["enabled"] as? Bool else { throw AppError.message("세션 ID와 설정값이 필요합니다.") }
                try setAutomatic(id, enabled: enabled); result = ["enabled": enabled]
            case "hook": result = params["autoapproveProtocol"] as? Int == 1 ? try handleClaudeHook(params) : handleHook(params)
            case "hookAck": try acknowledgeClaudeHook(params)
            case "claudeApprove":
                guard let id = params["sessionID"] as? String, let request = params["requestID"] as? String else { throw AppError.message("세션과 요청 ID가 필요합니다.") }
                try answerClaudeApproval(sessionID: id, requestID: request, enableAutomatic: params["enableAutomatic"] as? Bool ?? false)
            case "claudeRelease":
                guard let id = params["sessionID"] as? String, let request = params["requestID"] as? String else { throw AppError.message("세션과 요청 ID가 필요합니다.") }
                try releaseClaudeApproval(sessionID: id, requestID: request)
            case "register":
                guard let terminals = params["terminals"] as? [JSONObject], terminals.count <= 200 else { throw AppError.message("잘못된 터미널 등록입니다.") }
                peers[peer.id] = peer; bridges[peer.id] = terminals
                matchBridge(peer.id, terminals: terminals); snapshot.health.vscode = "연결됨 · \(bridges.count)개 창"; publish()
                var sizes: JSONObject = [:]
                for session in sessions.values where session.bridgeID == peer.id {
                    if let terminalID = session.terminalID, let size = ProcessDiscovery.terminalSize(tty: session.tty) {
                        sizes[terminalID] = ["columns": size.columns, "rows": size.rows]
                    }
                }
                result = ["terminalSizes": sizes]
            case "screen":
                guard peers[peer.id] != nil, let terminalID = params["terminalID"] as? String,
                      let screen = params["screen"] as? String, screen.utf8.count <= 200_000,
                      let generation = params["generation"] as? String else { throw AppError.message("등록되지 않은 터미널 화면입니다.") }
                for id in Array(sessions.keys) where sessions[id]?.agent != .shell && sessions[id]?.phase != .ended && sessions[id]?.bridgeID == peer.id && sessions[id]?.terminalID == terminalID {
                    if sessions[id]?.channel != .hook { sessions[id]?.channel = .vscodeScreen }
                    receiveScreen(sessionID: id, raw: screen, generation: peer.id + ":" + generation, source: .vscodeScreen)
                }
                publish()
            case "actionResult":
                if let id = params["actionID"] as? String, let action = pendingActions[id], action.peerID == peer.id,
                   let receipt = params["success"] as? NSNumber, CFGetTypeID(receipt) == CFBooleanGetTypeID() {
                    pendingActions.removeValue(forKey: id)
                    let succeeded = receipt.boolValue
                    if !succeeded { retryUnsentApproval(action.sessionID, dispatchID: action.dispatchID, generation: action.generation) }
                    if succeeded { watchDeliveredApproval(action.sessionID, dispatchID: action.dispatchID, generation: action.generation, requestIdentity: action.requestIdentity) }
                    var event = action.event
                    event.outcome = succeeded ? "승인 입력 전달" : "입력 미전달 · 새 화면 확인"
                    log(event)
                    publish()
                }
            default: throw AppError.message("지원하지 않는 요청입니다.")
            }
            var response: JSONObject = ["result": result]
            if let id = message["id"] { response["id"] = id }
            _ = peer.send(response)
        } catch {
            var response: JSONObject = ["error": error.localizedDescription]
            if let id = message["id"] { response["id"] = id }
            _ = peer.send(response)
        }
    }

    private func matchBridge(_ peerID: String, terminals: [JSONObject]) {
        for id in Array(sessions.keys) where sessions[id]?.phase != .ended {
            guard let session = sessions[id] else { continue }
            let tty = session.tty.replacingOccurrences(of: "/dev/", with: "")
            let ancestry = Set(ProcessDiscovery.ancestors(of: session.pid, records: records).prefix { $0.tty == "??" || $0.tty == tty }.map(\.pid))
            let matches = terminals.filter { terminal in
                guard let shellPID = (terminal["shellPID"] as? NSNumber)?.int32Value else { return false }
                return ancestry.contains(shellPID)
            }
            guard matches.count == 1, let match = matches.first, let terminalID = match["id"] as? String else { continue }
            sessions[id]?.terminal = .vscode; sessions[id]?.terminalID = terminalID; sessions[id]?.bridgeID = peerID
            sessions[id]?.terminalTitle = (match["name"] as? String).flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
            if session.agent == .shell {
                sessions[id]?.channel = .none
                if match["executionActive"] as? Bool == true {
                    sessions[id]?.setPhase(.working, detail: "VS Code가 명령 실행 중임을 알렸습니다.")
                }
            } else if session.channel != .hook {
                let attached = match["streamAttached"] as? Bool == true
                if !attached {
                    clearScreen(id)
                    sessions[id]?.setPhase(.unknown, detail: "현재 CLI 출력에 연결되지 않아 작업 상태를 확인할 수 없습니다.")
                }
                sessions[id]?.channel = attached ? .vscodeScreen : .none
                sessions[id]?.detail = attached ? "VS Code 출력 연결됨. 지원하는 권한 확인을 감지합니다." : "기존 출력에는 연결할 수 없습니다. Claude 훅을 연결하거나, 확장이 연결된 상태에서 CLI를 다시 실행·이어하기 해주세요."
            }
        }
    }

    private func disconnect(_ peerID: String) {
        peers.removeValue(forKey: peerID); bridges.removeValue(forKey: peerID)
        for id in Array(pendingActions.keys) where pendingActions[id]?.peerID == peerID {
            if var event = pendingActions.removeValue(forKey: id)?.event {
                event.outcome = "연결 끊김 · 입력 확인 필요"; log(event)
            }
        }
        for id in Array(sessions.keys) where sessions[id]?.bridgeID == peerID {
            sessions[id]?.bridgeID = nil; sessions[id]?.terminalID = nil
            if sessions[id]?.channel == .vscodeScreen { sessions[id]?.channel = .none; sessions[id]?.setPhase(.unknown, detail: "VS Code 연결이 끊겨 현재 상태를 확인할 수 없습니다.") }
            clearScreen(id)
        }
        snapshot.health.vscode = bridges.isEmpty ? "확장 연결 대기" : "연결됨 · \(bridges.count)개 창"
        publish()
    }

    private func clearScreen(_ id: String) {
        screens.removeValue(forKey: id); activityTrackers.removeValue(forKey: id); screenObservedAt.removeValue(forKey: id)
        sessions[id]?.pendingSummary = nil; sessions[id]?.pendingInTerminal = false
        sessions[id]?.pendingRequestID = nil
    }

    public func receiveScreen(sessionID: String, raw: String, generation: String, source: ApprovalChannel? = nil, at now: Date = Date()) {
        guard let session = sessions[sessionID], session.agent != .shell, session.phase != .ended else { return }
        // The original hook is still waiting in this app; screen input would be a second response path.
        guard !liveClaudeHooks.values.contains(where: { $0.request.sessionID == sessionID }) else { return }
        // A parked main terminal renders the child PTY. Its pixels cannot identify
        // which child owns the prompt; the child's hook is the response channel.
        guard !hasBackgroundChildren(sessionID), claudeParents[sessionID] == nil else { return }
        let prompt = PromptDetector.detect(raw, agent: session.agent)
        if session.channel == .hook {
            // A hook that already allowed the request must never be followed by a screen approval.
            guard session.phase == .approval, session.pendingInTerminal, prompt != nil,
                  source == .terminalScreen || source == .vscodeScreen else { return }
            sessions[sessionID]?.channel = source!
        } else if session.channel != .terminalScreen && session.channel != .vscodeScreen { return }
        defer { publish() }
        screenObservedAt[sessionID] = now
        guard let prompt else {
            let request = QuestionDetector.detect(raw, agent: session.agent)
            let observation = ActivityDetector.detect(raw, agent: session.agent)
            // An incomplete repaint is not evidence that a dispatched request finished.
            // Keep its reservation, but never dispatch from this unverified frame.
            if screens[sessionID]?.generation == generation, request?.phase != .input,
               observation.phase == .unknown || request?.phase == .approval {
                screens[sessionID]?.isCurrent = false
                screens[sessionID]?.scheduledID = nil
            } else {
                screens.removeValue(forKey: sessionID)
            }
            sessions[sessionID]?.pendingSummary = nil; sessions[sessionID]?.pendingInTerminal = false
            sessions[sessionID]?.pendingRequestID = nil
            if let request {
                activityTrackers.removeValue(forKey: sessionID)
                sessions[sessionID]?.setPhase(request.phase, detail: "터미널에서 요청에 응답해주세요.", at: now)
                sessions[sessionID]?.pendingSummary = request.summary; sessions[sessionID]?.pendingInTerminal = true
                sessions[sessionID]?.pendingRequestID = "screen:\(generation):\(PromptDetector.fingerprint(request.summary))"
                return
            }
            if let process = records.first(where: { $0.pid == session.pid }), !process.isForeground {
                activityTrackers.removeValue(forKey: sessionID)
                sessions[sessionID]?.setPhase(.unknown, detail: "CLI가 터미널의 입력 대상이 아닙니다. 백그라운드 실행 또는 일시정지 상태를 확인해주세요.", at: now)
                return
            }
            let activity = activityTrackers[sessionID, default: ActivityTracker()].observe(raw, agent: session.agent, generation: generation, at: now)
            sessions[sessionID]?.setPhase(activity.phase, detail: activity.detail, at: now, monitoring: activity.monitoring)
            return
        }
        activityTrackers.removeValue(forKey: sessionID)
        if let existing = screens[sessionID], existing.isCurrent, existing.generation == generation, existing.prompt.identity == prompt.identity {
            screens[sessionID]?.raw = raw; screens[sessionID]?.prompt = prompt
            scheduleScreenApproval(sessionID)
            return
        }
        // Codex can replace one permission dialog with the next between screen polls.
        // A new command must not inherit the preceding command's single-use reservation.
        // Formatting or choice-hint changes alone still cannot replay a sent input.
        let previous = screens[sessionID].flatMap {
            $0.generation == generation && (session.agent != .codex || $0.prompt.requestIdentity == prompt.requestIdentity) ? $0 : nil
        }
        var current = previous ?? ScreenState(raw: raw, prompt: prompt, generation: generation)
        // Coalesce render changes while process validation is in flight. The adapter
        // still receives the latest complete original dialog for its final check.
        if current.prompt.requestIdentity != prompt.requestIdentity { current.scheduledID = nil }
        current.raw = raw; current.prompt = prompt; current.isCurrent = true
        screens[sessionID] = current
        sessions[sessionID]?.setPhase(.approval, detail: current.reviewDetail ?? "터미널에서 실행 권한에 대한 응답을 기다리고 있습니다.", at: now)
        sessions[sessionID]?.pendingSummary = prompt.summary
        sessions[sessionID]?.pendingInTerminal = current.reviewDetail != nil
        sessions[sessionID]?.pendingRequestID = "screen:\(generation):\(prompt.requestIdentity)"
        sessions[sessionID]?.lastActivity = Date()
        scheduleScreenApproval(sessionID)
    }

    private func retryUnsentApproval(_ id: String, dispatchID: UUID, generation: String) {
        guard let state = screens[id], state.generation == generation, state.dispatchID == dispatchID else { return }
        screens[id]?.dispatchID = nil
        screens[id]?.validationFailures += 1
        // Only a definitive non-write enters this path. A fast repaint must not
        // permanently exhaust a retry budget; back off and require a fresh frame.
        let delay = min(4, 0.25 * pow(2, Double(min(state.validationFailures, 4))))
        screens[id]?.retryAfter = Date().addingTimeInterval(delay)
        screens[id]?.attempted = false
        screens[id]?.reviewDetail = nil
        if state.isCurrent {
            sessions[id]?.pendingInTerminal = false
            sessions[id]?.activityDetail = "화면이 바뀌어 승인 요청을 다시 확인하고 있습니다."
        }
    }

    private func requireApprovalReview(_ id: String, dispatchID: UUID, generation: String, requestIdentity: String, detail: String) {
        guard let state = screens[id], state.generation == generation, state.dispatchID == dispatchID,
              state.prompt.requestIdentity == requestIdentity else { return }
        screens[id]?.reviewDetail = detail
        guard state.isCurrent, sessions[id]?.phase == .approval else { return }
        sessions[id]?.pendingInTerminal = true
        sessions[id]?.activityDetail = detail
    }

    private func watchDeliveredApproval(_ id: String, dispatchID: UUID, generation: String, requestIdentity: String) {
        let deliveredAt = Date()
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard let self, self.screens[id]?.prompt.requestIdentity == requestIdentity,
                  let observed = self.screenObservedAt[id], observed > deliveredAt,
                  Date().timeIntervalSince(observed) < 6 else { return }
            self.requireApprovalReview(id, dispatchID: dispatchID, generation: generation, requestIdentity: requestIdentity,
                detail: "승인 입력을 전달했지만 같은 요청이 계속 표시됩니다. 터미널에서 입력 상태를 확인해주세요.")
            self.publish()
        }
    }

    private func watchApprovalAcknowledgement(_ actionID: String) {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard let self, let action = self.pendingActions.removeValue(forKey: actionID) else { return }
            self.requireApprovalReview(action.sessionID, dispatchID: action.dispatchID, generation: action.generation, requestIdentity: action.requestIdentity,
                detail: "VS Code의 승인 입력 전달 확인이 8초 안에 오지 않았습니다. 터미널에서 입력 상태를 확인해주세요.")
            var event = action.event
            event.outcome = "전달 확인 시간 초과 · 터미널 확인 필요"
            self.log(event)
            self.publish()
        }
    }

    private func scheduleScreenApproval(_ id: String) {
        guard !hasBackgroundChildren(id), claudeParents[id] == nil,
              let session = sessions[id], session.agent != .shell, session.automatic,
              session.channel == .terminalScreen || session.channel == .vscodeScreen, !snapshot.paused,
              let state = screens[id], state.isCurrent, !state.attempted, state.scheduledID == nil,
              state.retryAfter.map({ Date() >= $0 }) ?? true else { return }
        let scheduledRevision = revision
        let scheduledID = UUID()
        screens[id]?.scheduledID = scheduledID
        Task { [weak self] in
            let live = try? await Task.detached { try ProcessDiscovery.read() }.value
            guard let self else { return }
            guard self.revision == scheduledRevision, !self.snapshot.paused, self.sessions[id]?.automatic == true,
                  self.sessions[id]?.channel == session.channel,
                  self.sessions[id]?.bridgeID == session.bridgeID,
                  self.sessions[id]?.terminalID == session.terminalID,
                  let current = self.screens[id], current.isCurrent, !current.attempted,
                  current.scheduledID == scheduledID,
                  current.generation == state.generation,
                  current.prompt.requestIdentity == state.prompt.requestIdentity,
                  live?.contains(where: { $0.pid == session.pid && $0.started == session.started && $0.agent == session.agent
                      && "/dev/" + $0.tty == session.tty && $0.isForeground }) == true else {
                if self.screens[id]?.scheduledID == scheduledID { self.screens[id]?.scheduledID = nil }
                return
            }
            // Commit dispatch on the main actor. Pause cancels queued approvals, not an input already dispatched.
            self.screens[id]?.attempted = true; self.screens[id]?.scheduledID = nil; self.screens[id]?.dispatchID = scheduledID
            var event = AuditEvent(sessionID: id, summary: current.prompt.summary, outcome: "승인 시도 · 결과 미확인", source: session.channel == .terminalScreen ? "Terminal 화면" : "VS Code 화면",
                context: AuditContext(session: session), request: session.agent == .codex ? current.prompt.dialog : current.prompt.summary)
            // Persist the attempt before dispatch; a crash or missing acknowledgement remains traceable.
            guard self.log(event) else {
                self.sessions[id]?.pendingInTerminal = true
                self.sessions[id]?.activityDetail = "승인 내역을 저장하지 못했습니다. 터미널에서 요청을 확인해주세요."
                self.screens[id]?.reviewDetail = self.sessions[id]?.activityDetail
                self.publish(); return
            }
            if session.channel == .terminalScreen {
                do {
                    let delivery = try await Task.detached { try TerminalAdapter.approve(tty: session.tty, expectedScreen: current.raw, agent: session.agent) }.value
                    if delivery != .sent { self.retryUnsentApproval(id, dispatchID: scheduledID, generation: state.generation) }
                    if delivery == .sent { self.watchDeliveredApproval(id, dispatchID: scheduledID, generation: state.generation, requestIdentity: state.prompt.requestIdentity) }
                    event.outcome = delivery == .sent ? "승인 입력 전달" : "입력 미전달 · 새 화면 확인 (\(delivery.rawValue))"
                    self.log(event)
                } catch {
                    // A transport error can occur after dispatch; never blindly repeat an uncertain write.
                    self.requireApprovalReview(id, dispatchID: scheduledID, generation: state.generation, requestIdentity: state.prompt.requestIdentity,
                        detail: "승인 입력 결과를 확인하지 못했습니다. 터미널을 확인해주세요.")
                    event.outcome = "입력 확인 필요: \(error.localizedDescription)"; self.log(event)
                }
            } else if session.channel == .vscodeScreen, let peerID = session.bridgeID, let peer = self.peers[peerID], let terminalID = session.terminalID {
                let actionID = UUID().uuidString
                self.pendingActions[actionID] = (id, event, peerID, scheduledID, state.generation, state.prompt.requestIdentity)
                let sent = peer.send(["method": "approve", "id": actionID, "terminalID": terminalID, "fingerprint": current.prompt.fingerprint, "dialog": current.prompt.dialog, "agent": session.agent.rawValue, "answer": current.prompt.answer, "generation": String(state.generation.dropFirst(peerID.count + 1)), "expiresAt": Date().addingTimeInterval(2).timeIntervalSince1970 * 1000])
                if sent { self.watchApprovalAcknowledgement(actionID) }
                else {
                    self.pendingActions.removeValue(forKey: actionID)
                    self.requireApprovalReview(id, dispatchID: scheduledID, generation: state.generation, requestIdentity: state.prompt.requestIdentity,
                        detail: "VS Code로 승인 입력을 전달하지 못했습니다. 터미널 연결을 확인해주세요.")
                    event.outcome = "연결 끊김 · 입력 확인 필요"; self.log(event)
                }
            }
            self.publish()
        }
    }
}
