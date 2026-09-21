import Foundation
import Combine

@MainActor public final class ApprovalEngine: ObservableObject {
    @Published public private(set) var snapshot: EngineSnapshot
    @Published public private(set) var initialDiscoveryComplete = false
    public let paths: AppPaths
    private let store: AuditStore
    private let terminalReader: @Sendable ([String]) throws -> TerminalSnapshot
    private let codexQuestions = CodexQuestionCollector()
    private var codexCompletions = CodexCompletionTracker()
    private var claudeWorkIDs: [String: String] = [:]
    private let questionTransport: CodexReplyTransport
    private var replyingQuestions = Set<String>()
    private var sessions: [String: AgentSession] = [:]
    private var sessionOrder: [String] = []
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
        var scheduledID: UUID?
        var validationFailures = 0
        var dispatchID: UUID?
    }

    public init(paths: AppPaths = AppPaths(), terminalReader: @escaping @Sendable ([String]) throws -> TerminalSnapshot = { try TerminalAdapter.screens(ttys: $0) }, questionTransport: CodexReplyTransport = .live) throws {
        self.paths = paths
        self.terminalReader = terminalReader
        self.questionTransport = questionTransport
        try paths.prepare()
        store = try AuditStore(path: paths.database)
        if let saved = store.value("sessionOrder"),
           let ids = try? JSONDecoder().decode([String].self, from: Data(saved.utf8)) {
            var seen = Set<String>()
            sessionOrder = ids.filter { seen.insert($0).inserted }
        }
        snapshot = EngineSnapshot(sessions: [], events: store.recent(), paused: store.value("paused") == "true", health: ConnectionHealth())
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
        server?.stop(); server = nil
    }

    private func publish() {
        let ranks = Dictionary(uniqueKeysWithValues: sessionOrder.enumerated().map { ($0.element, $0.offset) })
        snapshot.sessions = sessions.values.sorted {
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

    public func refresh() async {
        guard !discovering else { return }
        discovering = true
        defer { discovering = false; initialDiscoveryComplete = true }
        do {
            let discovered = try await Task.detached(priority: .utility) { try ProcessDiscovery.read() }.value
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
                session.queuedQuestions = questions.filter { store.value("dismissedQuestion:\($0.id)") != "true" }.map { question in
                    var question = question
                    question.reply = session.questions.first(where: { $0.id == question.id })?.reply ?? savedReply(question.id)
                    return question
                }
                session.codexQuestionsObservedAt = date
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

    private func setReply(_ reply: QuestionReply, sessionID: String, questionID: String, persist: Bool) throws {
        if persist {
            try store.set("questionReply:\(questionID)", String(decoding: JSONEncoder().encode(reply), as: UTF8.self))
        }
        if let index = sessions[sessionID]?.queuedQuestions?.firstIndex(where: { $0.id == questionID }) {
            sessions[sessionID]?.queuedQuestions?[index].reply = reply
        }
        publish()
    }

    /// Explicit user action only. Queuing is an acknowledgement, not proof the
    /// running turn has received the answer. Uncertain submissions are not retried.
    public func replyToQuestion(sessionID: String, questionID: String, answer: String) async throws {
        guard let session = sessions[sessionID], session.agent == .codex, session.phase != .ended,
              let question = session.questions.first(where: { $0.id == questionID }),
              question.reply == nil || question.reply?.canRetry == true,
              replyingQuestions.insert(questionID).inserted else {
            throw AppError.message("이미 전송 중이거나 처리한 질문입니다. 현재 상태를 확인해주세요.")
        }
        defer { replyingQuestions.remove(questionID) }
        let answer = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = try CodexReplyTransport.message(question: question, answer: answer)
        let sending = QuestionReply(phase: .sending, answer: answer, message: "Codex 응답 경로를 확인하고 있습니다…")
        try setReply(sending, sessionID: sessionID, questionID: questionID, persist: false)
        var launched = false
        var audit: AuditEvent?
        do {
            let target = try await questionTransport.prepare(session, question)
            guard target.threadID == question.threadID, let current = sessions[sessionID], current.phase != .ended,
                  current.questions.contains(where: { $0.id == questionID }) else {
                throw AppError.message("세션이나 질문이 바뀌었습니다. 목록을 새로고침해주세요.")
            }
            let event = AuditEvent(sessionID: sessionID, summary: question.summary, outcome: "답변 전송 준비",
                source: "Codex 질문 응답", context: AuditContext(session: session), tool: "request_user_input_async", request: question.summary, answer: answer)
            guard log(event, session: session) else { throw AppError.message("답변 내역을 저장하지 못해 전송하지 않았습니다.") }
            audit = event
            // A crash after this reservation requires verification, never an automatic resend.
            try setReply(sending, sessionID: sessionID, questionID: questionID, persist: true)
            launched = true
            let queueID = try await questionTransport.send(target, message)
            let reply = QuestionReply(phase: .queued, answer: answer,
                message: "답변을 Codex 대기열에 넣었습니다. Codex가 받을 차례가 되면 전달됩니다.", queueID: queueID)
            do { try setReply(reply, sessionID: sessionID, questionID: questionID, persist: true) }
            catch {
                snapshot.health.auditError = error.localizedDescription
                try setReply(reply, sessionID: sessionID, questionID: questionID, persist: false)
            }
            audit?.outcome = "답변 대기열 등록"
            if let audit { log(audit, session: session) }
        } catch {
            let reply = QuestionReply(phase: launched ? .uncertain : .failed, answer: answer, message: error.localizedDescription)
            do { try setReply(reply, sessionID: sessionID, questionID: questionID, persist: true) }
            catch { try? setReply(reply, sessionID: sessionID, questionID: questionID, persist: false) }
            audit?.outcome = launched ? "답변 접수 확인 필요" : "답변 전송 전 중단"
            if let audit { log(audit, session: session) }
            throw error
        }
    }

    public func updateDiscovery(_ found: [AgentSession], records: [ProcessRecord], directories: [String: String] = [:]) {
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
                session.automatic = store.value("automatic:\(session.id)") == "true"
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
        guard var session = sessions[id], session.canApprove || !enabled else { throw AppError.message("이 세션의 승인 연결을 먼저 설정해주세요.") }
        try store.set("automatic:\(id)", enabled ? "true" : "false")
        session.automatic = enabled; sessions[id] = session
        screens[id]?.scheduledID = nil
        publish()
        if enabled { scheduleScreenApproval(id) }
    }
    public func setPaused(_ paused: Bool) throws {
        snapshot.paused = paused; revision &+= 1
        for id in screens.keys { screens[id]?.scheduledID = nil }
        try store.set("paused", paused ? "true" : "false")
        if !paused { for id in screens.keys { scheduleScreenApproval(id) } }
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
    public func removeClaude() throws {
        _ = try HookInstaller.install(executable: nil)
        snapshot.health.claude = "훅 연결 해제됨"
        for id in Array(sessions.keys) where sessions[id]?.channel == .hook {
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

    @discardableResult private func log(_ event: AuditEvent, session: AgentSession? = nil) -> Bool {
        var event = event
        if event.context == nil, let current = session ?? sessions[event.sessionID] { event.context = AuditContext(session: current) }
        do { try store.append(event); snapshot.health.auditError = nil }
        catch { snapshot.health.auditError = error.localizedDescription; return false }
        if let index = snapshot.events.firstIndex(where: { $0.id == event.id }) { snapshot.events[index] = event }
        else { snapshot.events.insert(event, at: 0) }
        if snapshot.events.count > 200 { snapshot.events.removeLast(snapshot.events.count - 200) }
        return true
    }

    /// The helper never retries. Duplicate or stale permission messages are passed to the original UI.
    public func handleHook(_ payload: JSONObject) -> JSONObject {
        guard let event = payload["hook_event_name"] as? String,
              let providerID = payload["session_id"] as? String, !providerID.isEmpty,
              let requestID = payload["requestID"] as? String else { return [:] }
        let pid = (payload["agentPID"] as? NSNumber)?.int32Value ?? 0
        let started = payload["agentStarted"] as? String ?? ""
        let key = pid > 0 && !started.isEmpty ? "process:\(pid):\(started)" : "claude:\(providerID)"
        var session = sessions[key] ?? AgentSession(id: key, agent: .claude, pid: pid, started: started, tty: payload["tty"] as? String ?? "", cwd: payload["cwd"] as? String ?? "", terminal: .unknown)
        guard session.agent == .claude else { return [:] }
        // Hooks can arrive before the first process scan after an app restart.
        if sessions[key] == nil { session.automatic = store.value("automatic:\(key)") == "true" }
        if let cwd = payload["cwd"] as? String, !cwd.isEmpty, session.cwd != cwd {
            session.cwd = cwd; session.gitBranch = nil
        }
        session.providerID = providerID; session.lastActivity = Date()
        // A hook owns this session now; any queued screen approval is obsolete.
        clearScreen(key)
        session.channel = event == "SessionEnd" ? .none : .hook
        session.detail = "Claude의 권한 요청을 직접 받습니다. 네트워크 확인 등 일부 요청은 터미널에서 처리합니다."
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
                if session.automatic, !snapshot.paused {
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
                } else {
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
            if session.automatic, !snapshot.paused, first, !needsAnswer {
                response = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": ["behavior": "allow"]]]
                session.setPhase(.working, detail: "권한을 승인해 작업을 계속합니다."); session.pendingSummary = nil; session.pendingInTerminal = false
                if !log(AuditEvent(sessionID: key, summary: summary, outcome: "승인 전달", source: "Claude 훅", tool: tool, request: request), session: session) {
                    response = [:]
                    session.setPhase(.approval, detail: "승인 내역을 저장하지 못했습니다. 터미널에서 요청을 확인해주세요.")
                    session.pendingSummary = summary; session.pendingInTerminal = true
                }
            } else if first {
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
            case "hook": result = handleHook(params)
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
                if let id = params["actionID"] as? String, let action = pendingActions[id], action.peerID == peer.id {
                    pendingActions.removeValue(forKey: id)
                    let succeeded = params["success"] as? Bool == true
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
            screens.removeValue(forKey: sessionID)
            sessions[sessionID]?.pendingSummary = nil; sessions[sessionID]?.pendingInTerminal = false
            sessions[sessionID]?.pendingRequestID = nil
            if let request = QuestionDetector.detect(raw, agent: session.agent) {
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
        if let existing = screens[sessionID], existing.generation == generation, existing.prompt.identity == prompt.identity {
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
        screens[sessionID] = ScreenState(raw: raw, prompt: prompt, attempted: previous?.attempted ?? false, generation: generation, validationFailures: previous?.validationFailures ?? 0, dispatchID: previous?.dispatchID)
        if previous?.attempted != true {
            sessions[sessionID]?.setPhase(.approval, detail: "터미널에서 실행 권한에 대한 응답을 기다리고 있습니다.", at: now)
        }
        sessions[sessionID]?.pendingSummary = prompt.summary
        sessions[sessionID]?.pendingInTerminal = previous != nil && session.pendingInTerminal
        sessions[sessionID]?.pendingRequestID = "screen:\(generation):\(prompt.requestIdentity)"
        sessions[sessionID]?.lastActivity = Date()
        scheduleScreenApproval(sessionID)
    }

    private func retryUnsentApproval(_ id: String, dispatchID: UUID, generation: String) {
        guard let state = screens[id], state.generation == generation, state.dispatchID == dispatchID else { return }
        screens[id]?.dispatchID = nil
        screens[id]?.validationFailures += 1
        if state.validationFailures < 3 {
            // The adapter confirms no input was sent. Wait for the next screen observation before retrying.
            screens[id]?.attempted = false
            sessions[id]?.activityDetail = "화면이 바뀌어 승인 요청을 다시 확인하고 있습니다."
        } else {
            sessions[id]?.pendingInTerminal = true
            sessions[id]?.activityDetail = "화면 확인이 반복해서 실패했습니다. 터미널에서 요청을 확인해주세요."
        }
    }

    private func requireApprovalReview(_ id: String, dispatchID: UUID, generation: String, requestIdentity: String, detail: String) {
        guard let state = screens[id], state.generation == generation, state.dispatchID == dispatchID,
              state.prompt.requestIdentity == requestIdentity, sessions[id]?.phase == .approval else { return }
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
        guard let session = sessions[id], session.agent != .shell, session.automatic,
              session.channel == .terminalScreen || session.channel == .vscodeScreen, !snapshot.paused,
              let state = screens[id], !state.attempted, state.scheduledID == nil else { return }
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
                  self.screens[id]?.scheduledID == scheduledID,
                  self.screens[id]?.generation == state.generation,
                  self.screens[id]?.prompt.identity == state.prompt.identity,
                  live?.contains(where: { $0.pid == session.pid && $0.started == session.started && $0.agent == session.agent
                      && "/dev/" + $0.tty == session.tty && $0.isForeground }) == true else {
                if self.screens[id]?.scheduledID == scheduledID { self.screens[id]?.scheduledID = nil }
                return
            }
            // Commit dispatch on the main actor. Pause cancels queued approvals, not an input already dispatched.
            self.screens[id]?.attempted = true; self.screens[id]?.scheduledID = nil; self.screens[id]?.dispatchID = scheduledID
            var event = AuditEvent(sessionID: id, summary: state.prompt.summary, outcome: "승인 시도 · 결과 미확인", source: session.channel == .terminalScreen ? "Terminal 화면" : "VS Code 화면",
                context: AuditContext(session: session), request: session.agent == .codex ? state.prompt.dialog : state.prompt.summary)
            // Persist the attempt before dispatch; a crash or missing acknowledgement remains traceable.
            guard self.log(event) else {
                self.sessions[id]?.pendingInTerminal = true
                self.sessions[id]?.activityDetail = "승인 내역을 저장하지 못했습니다. 터미널에서 요청을 확인해주세요."
                self.publish(); return
            }
            if session.channel == .terminalScreen {
                do {
                    let delivery = try await Task.detached { try TerminalAdapter.approve(tty: session.tty, expectedScreen: state.raw, agent: session.agent) }.value
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
                let current = self.screens[id] ?? state
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
