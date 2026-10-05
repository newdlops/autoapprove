import Foundation
import Combine
import TerminalInputSupport

@MainActor public final class ApprovalEngine: ObservableObject {
    @Published public private(set) var snapshot: EngineSnapshot
    @Published public private(set) var initialDiscoveryComplete = false
    @Published public private(set) var webStatus = RemoteNetworkStatus()
    public private(set) var webService: RemoteNetworkService?
    public let managedPTY: ManagedPTYManager
    private let tmuxRelay = TmuxRelay()
    private var ptyAutomatic: [String: Bool] = [:]
    private var ptyLifecycleObservers: [String: (terminal: ManagedPTY, token: UUID)] = [:]
    private struct RemoteOrcaBinding: Equatable, Sendable {
        let runtimeID: String
        let ptyID: String
        let incarnationID: String
        let ownerPID: Int32
        init(_ snapshot: OrcaTerminalSnapshot) {
            runtimeID = snapshot.runtimeID; ptyID = snapshot.ptyID; incarnationID = snapshot.incarnationID
            ownerPID = snapshot.ownerPID
        }
        var token: String { PromptDetector.fingerprint(runtimeID + "\u{0}" + ptyID + "\u{0}" + incarnationID + "\u{0}" + String(ownerPID)) }
    }
    private struct RemoteObservedScreen: Sendable { var raw: String; var generation: String; var observedAt: Date; var appearance: TerminalAppearance? = nil; var cursor: TerminalCursor? = nil; var orcaBinding: RemoteOrcaBinding? = nil }
    private struct RemoteScreenRead {
        var token: UUID
        var target: ScreenTarget
        var generation: String
        var task: Task<RemoteObservedScreen, Error>
        var observedAt: Date?
        var sourceRevision: UInt64?
    }
    private var remoteScreenReads: [String: RemoteScreenRead] = [:]
    private var remoteObservedScreens: [String: RemoteObservedScreen] = [:]
    private var remoteFrames: [String: (frame: RemoteTerminalFrame, raw: String, generation: String, orcaBinding: RemoteOrcaBinding?, nativeBinding: NativeBridgeBinding?)] = [:]
    private let orcaSnapshotReader: (@Sendable (String) async throws -> OrcaTerminalSnapshot)?
    private var remoteOrcaBindings: [String: (targetGeneration: String, binding: RemoteOrcaBinding)] = [:]
    private var remoteInputSessions = Set<String>()
    private var remotePTYInput = Set<String>()
    private var ptySessionBindings: [String: String] = [:]
    private var ptyContinuations: [String: (source: String, conversation: String?, ptyID: String)] = [:]
    private var ptyContinuationTasks: [String: Task<ManagedPTYDescriptor, Error>] = [:]
    private var automaticInputSessions = Set<String>()
    private var remoteInputUntil: [String: Date] = [:]
    private var remoteStreams: [String: (generation: String, token: String, identity: TTYInputIdentity?)] = [:]
    private var nativeWindowCaptures: [ScreenHost: TerminalWindowCapture] = [:]
    private var verifiedWindowCaptures: [String: TerminalWindowCapture] = [:]
    private var bridgeWindowCaptures: [String: (binding: NativeBridgeBinding, capture: TerminalWindowCapture)] = [:]
    private let requestTerminalKeyboardPermission: @MainActor @Sendable () -> Void
    private let terminalInputAvailable: @Sendable () -> Bool
    private let terminalInputIdentity: @Sendable (Int32) -> TTYInputIdentity?
    private let bridgeOwnerBundle: @MainActor @Sendable (Int32) -> String?
    private struct NativeBridgeBinding: Equatable, Sendable {
        var peerID: String
        var terminalID: String
        var generation: String
        var ownerPID: Int32
        var ownerBundleID: String
        var terminalName: String
        var windowToken: String
        var selected: Bool
    }
    private var remoteInputStopped = false
    private var remoteInputReplies: [String: (peerID: String, continuation: CheckedContinuation<Bool, Error>)] = [:]
    private var remoteRevealReplies: [String: (peerID: String, terminalID: String, continuation: CheckedContinuation<String?, Error>)] = [:]
    public let paths: AppPaths
    private let store: AuditStore
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
    private struct ScreenConnection {
        var enabled = false
        var polling = false
        var permissionBlocked = false
        var retryAfter = Date.distantPast
    }
    private var screenConnections: [ScreenHost: ScreenConnection] = [:]
    private let screenAdapters: [ScreenHost: ScreenHostAdapter]
    /// Seconds before each automatic continue within one run of capacity failures; its count is the limit.
    public var capacityResumeDelays: [TimeInterval] = [30, 60, 120, 240, 480]
    /// Wait after a final check that typed nothing, before trying the next fresh frame.
    public var capacityUnsentRetryDelay: TimeInterval = 3
    /// After a verified send, a frame read before it can still arrive. A stop that looks the same
    /// as the one answered counts as the next failure only after this long.
    public var capacityStaleFrameWindow: TimeInterval = 3
    /// A continued turn that keeps working this long made progress: its next stop starts a new run.
    public var capacityProgressWindow: TimeInterval = 120
    private struct CapacityState {
        enum Phase { case waiting, sending, sent, unavailable, review, exhausted, cancelled }
        var phase: Phase
        var stop: CodexCapacityStop
        var channel: ApprovalChannel
        var attempt: Int
        var deadline: Date
        var observedAt: Date
        var scheduledID: UUID?
        var sentAt: Date?
        var unsent = 0
    }
    private var capacityStates: [String: CapacityState] = [:]
    /// Work must be gone this long before the hold ends. It bridges a turn's end and the next approval or continue.
    public var keepAwakeGrace: TimeInterval = 120
    /// On battery at or below this percent the hold ends; macOS's own low-battery sleep is off while it holds.
    public var keepAwakeBatteryFloor = 20
    /// After a failed change to macOS sleep, wait this long before the next try.
    public var keepAwakeRetryDelay: TimeInterval = 60
    /// After heat ends a hold, the Mac must stay cool this long before it holds again, so a Mac near the limit
    /// doesn't flip it every few seconds.
    public var keepAwakeCoolDown: TimeInterval = 300
    private var keepAwakeCoolUntil: Date?
    /// Keep-awake checks read the time here; tests move it by hand.
    public var keepAwakeClock: @MainActor () -> Date = { Date() }
    private let powerControl: PowerControl
    private let keepAwakeSwitch: KeepAwakeSwitch
    private var keepAwakeEnabled = false
    /// nil: not checked since the last failure, which needs `sudo -n -l`.
    private var keepAwakeRule: Bool?
    private var keepAwakeWorkSeen: Date?
    private var keepAwakeRetryAfter = Date.distantPast
    private var keepAwakeFailure: String?
    private var keepAwakeEvaluating = false
    private var keepAwakeAgain = false
    private var keepAwakeWaiters: [CheckedContinuation<Void, Never>] = []
    /// Set by `stop()`: a check that resumes afterwards changes nothing.
    private var keepAwakeStopped = false
    private var keepAwakeTask: Task<Void, Never>?
    private var keepAwakeActivity: NSObjectProtocol?
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

    public init(paths: AppPaths = AppPaths(), terminalReader: @escaping @Sendable ([String]) throws -> TerminalSnapshot = { try TerminalAdapter.screens(ttys: $0) }, questionTransport: CodexReplyTransport = .live, claudeRegistryReader: @escaping @Sendable ([ProcessRecord]) -> [ClaudeSessionRegistration] = { ClaudeSessionRegistry.read(records: $0) }, processReader: @escaping @Sendable () throws -> [ProcessRecord] = { try ProcessDiscovery.read() }, screenAdapters: [ScreenHost: ScreenHostAdapter] = [:], powerControl: PowerControl = .live, managedPTY: ManagedPTYManager = ManagedPTYManager(), terminalWindowCapture: TerminalWindowCapture? = nil, itermWindowCapture: TerminalWindowCapture? = nil, orcaSnapshotReader: (@Sendable (String) async throws -> OrcaTerminalSnapshot)? = nil, requestTerminalKeyboardPermission: (@MainActor @Sendable () -> Void)? = nil, bridgeOwnerBundle: (@MainActor @Sendable (Int32) -> String?)? = nil, terminalInputAvailable: (@Sendable () -> Bool)? = nil,
                terminalInputIdentity: (@Sendable (Int32) -> TTYInputIdentity?)? = nil) throws {
        self.paths = paths
        self.managedPTY = managedPTY
        self.powerControl = powerControl
        keepAwakeSwitch = KeepAwakeSwitch(control: powerControl, marker: paths.directory.appendingPathComponent("keep-awake.hold").path)
        var adapters = Dictionary(uniqueKeysWithValues: ScreenHost.allCases.map { ($0, ScreenHostAdapter.live($0)) })
        adapters[.terminal]?.screens = { targets in try terminalReader(targets.map(\.tty)) }
        adapters[.pty] = managedPTY.adapter
        adapters[.tmux] = tmuxRelay.adapter
        self.screenAdapters = adapters.merging(screenAdapters) { _, explicit in explicit }
        self.questionTransport = questionTransport
        self.claudeRegistryReader = claudeRegistryReader
        self.processReader = processReader
        self.requestTerminalKeyboardPermission = requestTerminalKeyboardPermission ?? { _ = TerminalKeyboard.requestPermission() }
        self.terminalInputAvailable = terminalInputAvailable ?? { TerminalInputClient.shared.isAvailable }
        self.terminalInputIdentity = terminalInputIdentity ?? { try? TTYInputIdentity.capture(pid: $0) }
        self.bridgeOwnerBundle = bridgeOwnerBundle ?? { VSCodeWindowAdapter.ownerBundleID(ownerPID: $0) }
        // Explicit emulator adapters in fixtures do not inspect real native windows.
        if let terminalWindowCapture { nativeWindowCaptures[.terminal] = terminalWindowCapture }
        else if screenAdapters[.terminal] == nil { nativeWindowCaptures[.terminal] = TerminalWindowCapture() }
        if let itermWindowCapture { nativeWindowCaptures[.iterm] = itermWindowCapture }
        else if screenAdapters[.iterm] == nil { nativeWindowCaptures[.iterm] = TerminalWindowCapture(host: .iterm) }
        if let orcaSnapshotReader { self.orcaSnapshotReader = orcaSnapshotReader }
        else if screenAdapters[.orca] == nil {
            let source = OrcaTerminalStream()
            self.orcaSnapshotReader = { try await source.snapshot(handle: $0) }
        } else { self.orcaSnapshotReader = nil }
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
        keepAwakeEnabled = store.value("keepAwake") == "true"
        snapshot.keepAwake = keepAwakeEnabled ? KeepAwakeStatus(phase: .checking, detail: Self.keepAwakeChecking, enabled: true, ruleFile: powerControl.ruleFile())
            : KeepAwakeStatus(phase: .off, detail: Self.keepAwakeOff, enabled: false, ruleFile: powerControl.ruleFile())
        snapshot.health.claude = HookInstaller.isInstalled() ? "설치됨 · 세션 이벤트 대기" : "훅 설치 필요"
        // Restore only a connection the user explicitly enabled from the app.
        for host in ScreenHost.allCases {
            let enabled = host == .pty || (host == .tmux ? store.value(Self.enabledKey(host)) != "false" : store.value(Self.enabledKey(host)) == "true")
            screenConnections[host] = ScreenConnection(enabled: enabled)
            var health = snapshot.health.screen(host)
            health.requested = enabled
            if enabled { health.status = "저장된 \(host.title) 연결 복원 중…" }
            snapshot.health.setScreen(host, health)
        }
    }
    static func connectionGuide(_ session: AgentSession) -> String {
        if let host = ScreenHost(kind: session.terminal) { return "연결 설정에서 \(host.title) 연결 또는 Claude 훅을 설정하세요." }
        switch session.terminal {
        case .vscode: return "VS Code 확장을 연결하세요. 이미 실행 중인 Claude는 훅으로도 연결할 수 있습니다."
        case .unknown where session.hostName != nil:
            return "\(session.hostName!)의 화면은 읽을 수 없습니다. Claude는 훅으로 연결할 수 있습니다."
        default: return "연결 설정에서 Terminal 연결 또는 Claude 훅을 설정하세요."
        }
    }
    private static func enabledKey(_ host: ScreenHost) -> String { host == .terminal ? "terminalEnabled" : "screenHost.\(host.rawValue).enabled" }
    private func updateHealth(_ host: ScreenHost, _ change: (inout ScreenHostHealth) -> Void) {
        var health = snapshot.health.screen(host)
        change(&health)
        if health != snapshot.health.screen(host) { snapshot.health.setScreen(host, health) }
    }

    public func start(poll: Bool = true, webByDefault: Bool = false) throws {
        remoteInputStopped = false
        let socket = SocketServer(path: paths.socket, handler: { [weak self] message, peer in
            Task { @MainActor in self?.receive(message, from: peer) }
        }, disconnected: { [weak self] id in
            Task { @MainActor in self?.disconnect(id) }
        })
        try socket.start(); server = socket
        questionAutomationStopped = false
        keepAwakeStopped = false
        reconcileAutomaticQuestionReplies()
        let savedWeb = store.value("webEnabled")
        if savedWeb == "true" || (savedWeb == nil && webByDefault) {
            do { try setWebEnabled(true) }
            catch {
                webStatus.enabled = true
                webStatus.detail = "웹 연결을 열지 못했습니다. \(error.localizedDescription)"
            }
        }
        if poll {
            pollTask = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.refresh()
                    do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { break }
                }
            }
            // Screen reads can take many seconds; battery, heat and idle checks keep their own pace.
            keepAwakeTask = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.evaluateKeepAwake()
                    do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { break }
                }
            }
        }
    }
    public func stop() {
        remoteInputStopped = true
        for pending in ptyContinuationTasks.values { pending.cancel() }
        ptyContinuationTasks.removeAll()
        for observer in ptyLifecycleObservers.values { observer.terminal.removeOutputObserver(observer.token) }
        ptyLifecycleObservers.removeAll()
        managedPTY.stop()
        tmuxRelay.stop()
        revision &+= 1; pollTask?.cancel(); pollTask = nil
        gitBranchTask?.cancel(); gitBranchTask = nil
        keepAwakeTask?.cancel(); keepAwakeTask = nil
        questionAutomationStopped = true
        for id in Array(automaticQuestionReplies.keys) { cancelAutomaticQuestionReply(id) }
        server?.stop(); server = nil
        webService?.stop(); webService = nil
        for pending in remoteInputReplies.values { pending.continuation.resume(throwing: AppError.message("앱이 종료되어 입력 전달 결과를 확인하지 못했습니다.")) }
        for pending in remoteRevealReplies.values { pending.continuation.resume(throwing: AppError.message("앱이 종료되어 원본 창 연결을 확인하지 못했습니다.")) }; remoteRevealReplies.removeAll()
        for pending in remoteScreenReads.values { pending.task.cancel() }
        remoteInputReplies.removeAll(); remoteFrames.removeAll(); remoteObservedScreens.removeAll(); remoteScreenReads.removeAll(); remoteStreams.removeAll(); remoteOrcaBindings.removeAll()
        for capture in nativeWindowCaptures.values { capture.invalidate() }
        for capture in verifiedWindowCaptures.values { capture.invalidate() }
        for value in bridgeWindowCaptures.values { value.capture.invalidate() }; bridgeWindowCaptures.removeAll()
        // Quitting gives macOS its normal sleep back, without putting a closed Mac to sleep.
        keepAwakeStopped = true
        keepAwakeSwitch.releaseNow()
        setKeepAwakeActivity(false)
    }

    public func setWebEnabled(_ enabled: Bool, port: UInt16? = nil) throws {
        if enabled {
            if webService != nil {
                guard port != nil else { return }
                webService?.stop(); webService = nil
            }
            let nodeID = store.value("webNodeID") ?? UUID().uuidString
            try store.set("webNodeID", nodeID)
            let service = RemoteNetworkService(engine: self, nodeID: nodeID) { [weak self] status in
                guard let self else { return }
                self.webStatus = status
                if status.ready, let actualPort = status.port { try? self.store.set("webPort", String(actualPort)) }
            }
            let preferredPort = port ?? store.value("webPort").flatMap(UInt16.init) ?? 8765
            try service.start(port: preferredPort, allowPortFallback: port == nil)
            do { try store.set("webEnabled", "true") }
            catch { service.stop(); throw error }
            webService = service
        } else {
            try store.set("webEnabled", "false")
            webService?.stop(); webService = nil
        }
    }

    public func remoteSessionViews() -> [RemoteSessionView] {
        snapshot.sessions.filter { $0.phase != .ended }.compactMap { session -> RemoteSessionView? in
            let canRead = remoteCanRead(session) || nativeWindowCapture(for: session) != nil || usesOrcaSnapshot(session)
            let ptyID = session.id.hasPrefix("pty:") ? String(session.id.dropFirst(4)) : ptySessionBindings[session.id]
            let terminal = ptyID.flatMap { try? managedPTY.terminal($0) }
            if let terminal, !terminal.isRunning { return nil }
            let pty = terminal?.descriptor
            return RemoteSessionView(session: session,
                title: session.customization?.title.isEmpty == false ? session.customization!.title : session.terminalTitle ?? session.project,
                phaseTitle: session.phaseTitle, canApprove: session.canApprove, canReveal: session.canReveal,
                canRead: canRead, inputReason: remoteInputReason(session), keys: canRead && (!usesOrcaSnapshot(session) || remoteCanRead(session)) ? remoteKeys(session) : [],
                ptyID: pty?.ptyID, pty: pty)
        }
    }
    private func synchronizePTYContainers() {
        let inventory = managedPTY.inventory
        let activePTYs = Set(sessions.values.filter { $0.agent != .shell && $0.phase != .ended }.compactMap { ptySessionBindings[$0.id] })
        for terminal in inventory {
            let id = "pty:" + terminal.ptyID
            let running = (try? managedPTY.terminal(terminal.ptyID).isRunning) == true
            if running, activePTYs.contains(terminal.ptyID) { sessions.removeValue(forKey: id); continue }
            var session = AgentSession(id: id, agent: .shell, pid: terminal.pid, started: terminal.streamID, tty: terminal.tty, cwd: terminal.cwd, terminal: .pty)
            session.terminalTitle = "PTY · " + URL(fileURLWithPath: terminal.cwd).lastPathComponent
            session.channel = running ? .ptyScreen : .none
            session.phase = running ? .idle : .ended
            session.detail = terminal.exitCode.map { "PTY 종료 · 종료 코드 \($0). 마지막 출력은 계속 볼 수 있습니다." } ?? "PTY 화면을 눌러 직접 입력하세요. Codex·Claude를 실행하면 자동 승인도 사용할 수 있습니다."
            sessions[id] = session
        }
        let keep = Set(inventory.map { "pty:" + $0.ptyID })
        for id in Array(sessions.keys) where id.hasPrefix("pty:") && !keep.contains(id) { sessions.removeValue(forKey: id) }
    }
    public func createPTY(_ object: JSONObject) async throws -> ManagedPTYDescriptor {
        guard !remoteInputStopped else { throw RemoteHTTPError(503, "앱이 종료 중입니다.") }
        guard let id = object["sessionID"] as? String, object["reuse"] as? Bool == true else {
            return try await spawnPTY(object)
        }
        let supplied = object["conversationID"] as? String
        if let supplied, UUID(uuidString: supplied) == nil { throw RemoteHTTPError(400, "올바른 대화 ID를 입력해주세요.") }
        guard let session = sessions[id], session.phase != .ended else {
            if let saved = ptyContinuations[id], supplied == nil || UUID(uuidString: supplied!)?.uuidString == saved.conversation {
                guard let terminal = try? managedPTY.terminal(saved.ptyID) else { throw RemoteHTTPError(410, "이 PTY는 종료됐습니다. 새 터미널을 열어 대화를 다시 선택해주세요.") }
                return terminal.descriptor
            }
            throw RemoteHTTPError(409, "이어갈 CLI 세션을 다시 선택해주세요.")
        }
        if supplied == nil, let owned = ptySessionBindings[id], let terminal = try? managedPTY.terminal(owned) { return terminal.descriptor }
        let reader = processReader
        let live = try await Task.detached { try reader() }.value
        guard live.contains(where: { $0.pid == session.pid && $0.started == session.started && $0.agent == session.agent && "/dev/" + $0.tty == session.tty }) else { throw RemoteHTTPError(409, "원래 CLI 세션이 바뀌었습니다. 목록을 새로고침해주세요.") }
        // /new and /resume can change the conversation without changing the PID.
        // Resolve the live provider identity before reusing a previous fork.
        let observed: String?
        if let supplied { observed = supplied } else { observed = await currentPTYConversation(session, records: live) }
        if let observed, UUID(uuidString: observed) == nil { throw RemoteHTTPError(400, "올바른 대화 ID를 입력해주세요.") }
        let conversation = observed.flatMap { UUID(uuidString: $0)?.uuidString }
        let source = "\(session.id)|\(session.pid)|\(session.started)|\(session.tty)|\(session.agent.rawValue)|\(session.cwd)|\(conversation ?? "picker")"
        if let saved = ptyContinuations[id], source == saved.source {
            guard let terminal = try? managedPTY.terminal(saved.ptyID) else { throw RemoteHTTPError(410, "이 PTY는 종료됐습니다. 새 터미널을 열어 대화를 다시 선택해주세요.") }
            return terminal.descriptor
        }
        if let pending = ptyContinuationTasks[source] { return try await pending.value }
        var verified = object
        if let observed { verified["conversationID"] = observed }
        let request = verified
        let pending = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { throw CancellationError() }
            return try await self.spawnPTY(request)
        }
        ptyContinuationTasks[source] = pending
        defer { ptyContinuationTasks.removeValue(forKey: source) }
        let terminal = try await pending.value
        // Remember that a continuation ended even after its bounded screen is
        // evicted. Selecting the same source must not silently fork again.
        ptyContinuations = ptyContinuations.filter { sessions[$0.key] != nil }
        ptyContinuations[id] = (source, conversation, terminal.ptyID)
        return terminal
    }
    private func currentPTYConversation(_ session: AgentSession, records: [ProcessRecord]) async -> String? {
        if session.agent == .codex {
            let pid = session.pid
            return try? await Task.detached {
                let files = try CommandRunner.run("/usr/sbin/lsof", ["-a", "-p", String(pid), "-Fpn"], timeout: 5)
                return try CodexThreadLocation.locate(paths: CodexThreadLocation.openFiles(files.output)[pid] ?? []).threadID
            }.value
        }
        let registryReader = claudeRegistryReader, key = session.id
        let registrations = await Task.detached { registryReader(records).filter { $0.processID == key } }.value
        return registrations.count == 1 ? registrations.first?.activity?.providerID : nil
    }
    private func spawnPTY(_ object: JSONObject) async throws -> ManagedPTYDescriptor {
        guard !remoteInputStopped else { throw RemoteHTTPError(503, "앱이 종료 중입니다.") }
        var cwd = object["cwd"] as? String ?? NSHomeDirectory()
        var program = object["program"] as? String ?? "shell"
        var command: [String]?
        if let id = object["sessionID"] as? String {
            guard let session = sessions[id], session.phase != .ended, session.agent != .shell else { throw RemoteHTTPError(409, "이어갈 CLI 세션을 다시 선택해주세요.") }
            let reader = processReader
            let live = try await Task.detached { try reader() }.value
            guard let record = live.first(where: { $0.pid == session.pid && $0.started == session.started && $0.agent == session.agent && "/dev/" + $0.tty == session.tty }) else { throw RemoteHTTPError(409, "원래 CLI 세션이 바뀌었습니다. 목록을 새로고침해주세요.") }
            cwd = session.cwd; program = session.agent.rawValue
            let supplied = object["conversationID"] as? String
            var conversation = supplied ?? (session.agent == .codex ? questionThreadBySession[id] : session.providerID)
            if supplied == nil { conversation = await currentPTYConversation(session, records: live) }
            if let conversation, UUID(uuidString: conversation) == nil { throw RemoteHTTPError(400, "올바른 대화 ID를 입력해주세요.") }
            let fresh = try await Task.detached { try reader() }.value
            guard !remoteInputStopped, fresh.contains(where: { $0.key == record.key && $0.agent == session.agent && "/dev/" + $0.tty == session.tty }), sessions[id]?.pid == session.pid else { throw RemoteHTTPError(409, "원래 CLI가 종료되었거나 바뀌었습니다.") }
            // Fork the recorded conversation, preserving the original running TUI.
            // Without an exact ID, open the provider's picker; never choose --last.
            command = session.agent == .codex ? [record.executable, "fork"] + (conversation.map { [$0] } ?? [])
                : [record.executable, "--resume"] + (conversation.map { [$0] } ?? []) + ["--fork-session"]
        }
        try Task.checkCancellation()
        let terminal = try managedPTY.create(cwd: cwd, program: program, command: command, columns: object["columns"] as? Int ?? 80, rows: object["rows"] as? Int ?? 24)
        ptyAutomatic[terminal.ptyID] = object["automatic"] as? Bool == true
        let owned = try managedPTY.terminal(terminal.ptyID), id = terminal.ptyID
        let observer = owned.observeOutput { [weak self, weak owned] in
            guard owned?.isRunning == false else { return }
            Task { @MainActor [weak self] in
                guard let self, !self.remoteInputStopped, self.ptyLifecycleObservers[id] != nil else { return }
                self.finishPTY(id)
            }
        }
        ptyLifecycleObservers[id] = (owned, observer)
        if !owned.isRunning { finishPTY(id) }
        synchronizePTYContainers(); publish()
        Task { [weak self] in await self?.refresh() }
        return terminal
    }
    public func ptyInput(_ object: JSONObject) async throws -> JSONObject {
        guard !remoteInputStopped, let id = object["ptyID"] as? String, let stream = object["streamID"] as? String,
              let client = object["clientID"] as? String, let sequence = object["sequence"] as? Int,
              let encoded = object["data"] as? String, let data = Data(base64Encoded: encoded) else { throw RemoteHTTPError(400, "PTY 연결과 입력 바이트를 지정해주세요.") }
        let terminal = try managedPTY.terminal(id)
        let members = sessions.values.filter { $0.tty == terminal.descriptor.tty && $0.phase != .ended }.map(\.id)
        guard !remotePTYInput.contains(id), !members.contains(where: { remoteInputSessions.contains($0) }) else { throw RemoteHTTPError(409, "다른 PTY 입력이 진행 중입니다. 화면을 확인해주세요.") }
        remotePTYInput.insert(id)
        for member in members { remoteInputSessions.insert(member); screens[member]?.scheduledID = nil }
        defer {
            remotePTYInput.remove(id)
            for member in members { remoteInputSessions.remove(member); remoteInputUntil[member] = Date().addingTimeInterval(0.8) }
            Task { [weak self] in try? await Task.sleep(nanoseconds: 810_000_000); await self?.refreshScreenHost(.pty) }
        }
        let deadline = Date().addingTimeInterval(5)
        while members.contains(where: automaticInputBusy), Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        guard !remoteInputStopped, !members.contains(where: automaticInputBusy) else { throw RemoteHTTPError(409, "진행 중인 승인 입력이 끝나지 않았습니다. 화면을 확인해주세요.") }
        try await Task.detached { try terminal.input(data, streamID: stream, client: client, sequence: sequence) }.value
        return ["accepted": true, "sequence": sequence]
    }
    public func ptyResize(_ object: JSONObject) throws -> JSONObject {
        guard !remoteInputStopped, let id = object["ptyID"] as? String, let stream = object["streamID"] as? String,
              let client = object["clientID"] as? String, let columns = object["columns"] as? Int, let rows = object["rows"] as? Int else { throw RemoteHTTPError(400, "PTY 연결과 화면 크기를 지정해주세요.") }
        let terminal = try managedPTY.terminal(id)
        try terminal.resize(columns: columns, rows: rows, streamID: stream, client: client)
        for member in sessions.values where member.tty == terminal.descriptor.tty { screens[member.id]?.scheduledID = nil; remoteInputUntil[member.id] = Date().addingTimeInterval(0.8) }
        return ["accepted": true]
    }
    public func ptyClose(_ object: JSONObject) throws -> JSONObject {
        guard let id = object["ptyID"] as? String, let stream = object["streamID"] as? String else { throw RemoteHTTPError(400, "종료할 PTY 연결을 지정해주세요.") }
        let terminal = try managedPTY.terminal(id)
        guard terminal.descriptor.streamID == stream else { throw RemoteHTTPError(409, "PTY 연결이 바뀌었습니다.") }
        terminal.close()
        finishPTY(id)
        return ["accepted": true]
    }
    private func finishPTY(_ id: String) {
        if let observer = ptyLifecycleObservers.removeValue(forKey: id) { observer.terminal.removeOutputObserver(observer.token) }
        for key in ptySessionBindings.keys where ptySessionBindings[key] == id {
            sessions[key]?.setPhase(.ended, detail: "PTY가 종료되었습니다.")
            sessions[key]?.channel = .none; sessions[key]?.automatic = false
            sessions[key]?.queuedQuestions = []; sessions[key]?.codexQuestionsError = nil
            clearScreen(key); capacityStates.removeValue(forKey: key)
        }
        ptyAutomatic[id] = false
        synchronizePTYContainers(); publish()
    }
    private func remoteCanRead(_ session: AgentSession) -> Bool {
        guard session.phase != .ended else { return false }
        if let host = ScreenHost(kind: session.terminal) { return screenConnections[host]?.enabled == true && !session.tty.isEmpty }
        return session.terminal == .vscode && session.bridgeID != nil && (remoteObservedScreens[session.id] != nil || nativeBridgeBinding(session) != nil)
    }
    public func remoteTmuxObservation(sessionID: String) throws -> TmuxRelayObservation? {
        guard let session = sessions[sessionID], session.terminal == .tmux, remoteCanRead(session) else { return nil }
        return try tmuxRelay.observe(ScreenTarget(tty: session.tty, handle: session.tmuxHandle))
    }
    private func usesOrcaSnapshot(_ session: AgentSession) -> Bool { session.terminal == .orca && orcaSnapshotReader != nil }
    private func remoteKeys(_ session: AgentSession) -> [String] {
        let basic = ["text", "enter", "escape", "interrupt", "up", "down", "tab"]
        let interactive = ["submit", "characters", "left", "right", "backspace", "delete", "home", "end"]
        if session.terminal == .terminal {
            return terminalInputAvailable() ? basic + interactive : ["text", "submit", "enter"]
        }
        if usesOrcaSnapshot(session) {
            return ["characters", "enter", "escape", "interrupt", "up", "down", "left", "right", "backspace", "delete", "home", "end", "tab"]
        }
        if session.terminal == .vscode {
            let registration = session.bridgeID.flatMap { bridges[$0] }?.first { $0["id"] as? String == session.terminalID }
            return basic + ((registration?["remoteInputVersion"] as? Int ?? 0) >= 2 ? interactive : [])
        }
        return basic + interactive
    }
    private func remoteInputReason(_ session: AgentSession) -> String? {
        if !remoteCanRead(session) { return "이 세션의 화면 연결이 없습니다. Mac의 연결 설정에서 터미널을 연결해주세요. 훅으로 받은 질문은 아래에서 답할 수 있습니다." }
        if session.terminal == .vscode {
            let registration = session.bridgeID.flatMap { bridges[$0] }?.first { $0["id"] as? String == session.terminalID }
            if (registration?["remoteInputVersion"] as? Int ?? 0) < 1 { return "Mac에서 AutoApprove Bridge 확장을 업데이트하면 웹에서 입력할 수 있습니다." }
        }
        return nil
    }

    private func readRemoteScreen(_ session: AgentSession, host: ScreenHost, adapter: ScreenHostAdapter, realtime: Bool = false) async throws -> RemoteObservedScreen {
        let target = ScreenTarget(tty: session.tty, handle: session.screenHandle)
        let generation = remoteGeneration(session, host: host)
        let pending: RemoteScreenRead
        let cacheAge: TimeInterval = userInputHasPriority(session.id) ? 0.12 : realtime ? 0.18 : 0.6
        let sourceRevision = host == .tmux ? tmuxRelay.sourceRevision(target) : nil
        if let existing = remoteScreenReads[session.id], existing.target == target, existing.generation == generation,
           existing.observedAt.map({ existing.sourceRevision == sourceRevision && Date().timeIntervalSince($0) < cacheAge }) ?? true {
            pending = existing
        } else {
            let reader = adapter.screens
            let task = Task.detached(priority: .userInitiated) {
                let snapshot = try reader([target])
                guard let screen = snapshot.screens.first(where: { $0.tty == target.tty }) else {
                    throw RemoteHTTPError(409, snapshot.failures.first?.message ?? "터미널 화면을 찾지 못했습니다.")
                }
                return RemoteObservedScreen(raw: screen.contents, generation: generation, observedAt: Date(), appearance: screen.appearance?.validated(for: screen.contents), cursor: screen.cursor?.validated(for: screen.contents))
            }
            pending = RemoteScreenRead(token: UUID(), target: target, generation: generation, task: task)
            var tracked = pending; tracked.sourceRevision = sourceRevision
            remoteScreenReads[session.id] = tracked
        }
        do {
            let observed = try await pending.task.value
            guard remoteScreenReads[session.id]?.token == pending.token else {
                throw RemoteHTTPError(409, "화면 연결이나 입력 상태가 바뀌었습니다. 최신 화면을 다시 확인해주세요.")
            }
            remoteScreenReads[session.id]?.observedAt = observed.observedAt
            return observed
        } catch {
            if remoteScreenReads[session.id]?.token == pending.token { remoteScreenReads.removeValue(forKey: session.id) }
            throw error
        }
    }

    nonisolated private static func validateOrcaSnapshot(_ snapshot: OrcaTerminalSnapshot) throws {
        guard [snapshot.runtimeID, snapshot.ptyID, snapshot.incarnationID].allSatisfy({ !$0.isEmpty && $0.utf8.count <= 1024 }),
              snapshot.ownerPID > 0, snapshot.sequence >= 0, Date().timeIntervalSince(snapshot.observedAt) < 10,
              snapshot.observedAt.timeIntervalSinceNow <= 1 else {
            throw OrcaTerminalStreamError.unavailable("현재 원본 세션의 식별자나 관찰 시간을 확인하지 못했습니다.")
        }
    }
    nonisolated private static func orcaOwner(_ pid: Int32, tty: String, records: [ProcessRecord]) throws -> ProcessRecord {
        let name = tty.replacingOccurrences(of: "/dev/", with: "")
        guard let owner = records.first(where: { $0.pid == pid && $0.tty == name }) else {
            throw OrcaTerminalStreamError.unavailable("데몬의 원래 PTY 소유 프로세스가 선택한 CLI의 TTY와 다릅니다. 다른 터미널은 공유하지 않습니다.")
        }
        return owner
    }
    private func readOrcaScreen(_ session: AgentSession, realtime: Bool) async throws -> RemoteObservedScreen {
        guard let reader = orcaSnapshotReader, let handle = session.orcaHandle else {
            throw OrcaTerminalStreamError.unavailable("원래 터미널 핸들을 확인하지 못했습니다.")
        }
        let target = ScreenTarget(tty: session.tty, handle: handle)
        let targetGeneration = remoteGeneration(session, host: .orca), generation = targetGeneration + ":ansi"
        let cacheAge: TimeInterval = userInputHasPriority(session.id) ? 0.12 : realtime ? 0.18 : 0.6
        let pending: RemoteScreenRead
        if let existing = remoteScreenReads[session.id], existing.target == target, existing.generation == generation,
           existing.observedAt.map({ Date().timeIntervalSince($0) < cacheAge }) ?? true {
            pending = existing
        } else {
            let identity = nativeIdentity(session), tty = session.tty, recordReader = processReader
            let pid = session.pid, started = session.started, agent = session.agent.rawValue
            let task = Task.detached(priority: .userInitiated) {
                guard try identity() else { throw RemoteHTTPError(409, "원래 Orca CLI의 PID 또는 TTY가 바뀌었습니다. 목록을 새로고침해주세요.") }
                let snapshot = try await reader(handle)
                try Task.checkCancellation(); try Self.validateOrcaSnapshot(snapshot)
                let owner = try Self.orcaOwner(snapshot.ownerPID, tty: tty, records: recordReader())
                let rendered = try OriginalTerminalScreen.render(ansi: snapshot.ansi, columns: snapshot.columns, rows: snapshot.rows, tty: tty)
                let after = try recordReader()
                let currentOwner = try Self.orcaOwner(snapshot.ownerPID, tty: tty, records: after)
                guard currentOwner.key == owner.key else { throw OrcaTerminalStreamError.unavailable("화면을 읽는 동안 원래 PTY 소유 프로세스가 바뀌었습니다.") }
                guard after.contains(where: { $0.pid == pid && $0.started == started && "/dev/" + $0.tty == tty && $0.agent?.rawValue == agent && $0.isForeground }) else { throw RemoteHTTPError(409, "화면을 읽는 동안 원래 Orca CLI가 종료되거나 바뀌었습니다.") }
                let binding = RemoteOrcaBinding(snapshot)
                return RemoteObservedScreen(raw: rendered.contents, generation: generation + ":" + binding.token,
                    observedAt: snapshot.observedAt, appearance: rendered.appearance, cursor: rendered.cursor, orcaBinding: binding)
            }
            pending = RemoteScreenRead(token: UUID(), target: target, generation: generation, task: task)
            remoteScreenReads[session.id] = pending
        }
        do {
            let observed = try await pending.task.value; try Task.checkCancellation()
            guard remoteScreenReads[session.id]?.token == pending.token else {
                throw RemoteHTTPError(409, "원래 Orca 화면 연결이 바뀌었습니다. 다시 연결해주세요.")
            }
            guard let binding = observed.orcaBinding else { throw OrcaTerminalStreamError.unavailable("원래 PTY의 세대를 확인하지 못했습니다.") }
            if let original = remoteOrcaBindings[session.id], original.targetGeneration == targetGeneration, original.binding != binding {
                throw OrcaTerminalStreamError.unavailable("같은 핸들의 PTY 세대가 바뀌어 다른 터미널 화면을 공유하지 않습니다. Mac에서 원래 CLI를 확인해주세요.")
            }
            remoteOrcaBindings[session.id] = (targetGeneration, binding)
            remoteScreenReads[session.id]?.observedAt = observed.observedAt
            return observed
        } catch {
            if remoteScreenReads[session.id]?.token == pending.token { remoteScreenReads.removeValue(forKey: session.id) }
            throw error
        }
    }

    private func remoteGeneration(_ session: AgentSession, host: ScreenHost) -> String {
        "\(host.rawValue):\(session.id):\(session.pid):\(session.started):\(session.tty):\(session.screenHandle ?? "")"
    }
    private func invalidateRemoteRead(_ id: String) {
        // A concurrent reader still owns its token; do not turn a valid live read into a disconnect.
        if remoteScreenReads[id]?.observedAt != nil { remoteScreenReads[id]?.observedAt = .distantPast }
    }

    /// A source-specific adapter may register only a verified exact native window.
    /// The capture service still checks selected metadata, immutable owner and CLI identity.
    public func setNativeWindowCapture(sessionID: String, capture: TerminalWindowCapture?) {
        verifiedWindowCaptures.removeValue(forKey: sessionID)?.invalidate()
        if let capture { verifiedWindowCaptures[sessionID] = capture }
        remoteFrames.removeValue(forKey: sessionID)
    }
    private func nativeBridgeBinding(_ session: AgentSession, requireWindowIdentity: Bool = false) -> NativeBridgeBinding? {
        guard session.terminal == .vscode, let peerID = session.bridgeID, peers[peerID] != nil,
              let terminalID = session.terminalID,
              let registration = bridges[peerID]?.first(where: { $0["id"] as? String == terminalID }),
              let windowVersion = registration["nativeWindowVersion"] as? Int, windowVersion >= 0,
              !requireWindowIdentity || windowVersion >= 2,
              (registration["remoteInputVersion"] as? Int ?? 0) >= 3,
              let number = registration["ownerPID"] as? Int, let ownerPID = Int32(exactly: number), ownerPID > 0,
              let generation = registration["nativeGeneration"] as? String, !generation.isEmpty, generation.utf8.count <= 256,
              let name = registration["name"] as? String, name.utf8.count <= 4096,
              let windowToken = registration["windowToken"] as? String, windowToken.utf8.count == 36, UUID(uuidString: windowToken) != nil,
              !requireWindowIdentity || bridges[peerID]?.filter({ $0["name"] as? String == name }).count == 1,
              let owner = bridgeOwnerBundle(ownerPID) else { return nil }
        return NativeBridgeBinding(peerID: peerID, terminalID: terminalID, generation: generation, ownerPID: ownerPID,
            ownerBundleID: owner, terminalName: name, windowToken: windowToken, selected: registration["selected"] as? Bool == true)
    }
    private func nativeBridgeGeneration(_ binding: NativeBridgeBinding) -> String {
        "\(binding.peerID):native:\(binding.terminalID):\(binding.generation):\(binding.ownerPID):\(binding.windowToken)"
    }
    private func nativeIdentity(_ session: AgentSession) -> @Sendable () throws -> Bool {
        let reader = processReader, pid = session.pid, started = session.started, tty = session.tty.replacingOccurrences(of: "/dev/", with: ""), agent = session.agent.rawValue
        return {
            try reader().contains { $0.pid == pid && $0.started == started && $0.tty == tty && $0.agent?.rawValue == agent && $0.isForeground }
        }
    }
    private func nativeWindowCapture(for session: AgentSession) -> TerminalWindowCapture? {
        if let verified = verifiedWindowCaptures[session.id] { return verified }
        if let host = ScreenHost(kind: session.terminal), let capture = nativeWindowCaptures[host] { return capture }
        guard let binding = nativeBridgeBinding(session, requireWindowIdentity: true) else { return nil }
        if let existing = bridgeWindowCaptures[session.id], existing.binding == binding { return existing.capture }
        bridgeWindowCaptures.removeValue(forKey: session.id)?.capture.invalidate()
        let id = session.id
        let capture = TerminalWindowCapture(host: .orca, ownerBundleID: binding.ownerBundleID, requiresAccessibilityForMetadata: true,
            permissions: { TerminalWindowPermissions(screen: TerminalWindowCapture.screenPermissionGranted, keyboard: TerminalKeyboard.isAvailable, automation: true) },
            metadata: { [weak self] tty in
                guard let self else { return nil }
                return try await self.nativeBridgeWindowMetadata(sessionID: id, tty: tty, binding: binding)
            })
        bridgeWindowCaptures[id] = (binding, capture)
        return capture
    }
    private func nativeBridgeWindowMetadata(sessionID: String, tty: String, binding: NativeBridgeBinding) async throws -> TerminalWindowMetadata? {
        guard let session = sessions[sessionID], session.tty == tty, nativeBridgeBinding(session, requireWindowIdentity: true) == binding, binding.selected else { return nil }
        let token = nativeBridgeGeneration(binding)
        let metadata = try await Task.detached {
            try VSCodeWindowAdapter.metadata(ownerPID: binding.ownerPID, tty: tty, selected: binding.selected, bindingToken: token, terminalName: binding.terminalName, windowToken: binding.windowToken)
        }.value
        guard let current = sessions[sessionID], current.tty == tty, nativeBridgeBinding(current, requireWindowIdentity: true) == binding else { return nil }
        return metadata
    }

    public func connectRemoteTerminal(_ object: JSONObject) async throws -> RemoteTerminalFrame {
        guard !remoteInputStopped, let id = object["sessionID"] as? String, let session = sessions[id], session.phase != .ended,
              session.terminal != .pty else { throw RemoteHTTPError(409, "연결할 원래 CLI 세션을 찾지 못했습니다.") }
        if session.terminal == .vscode, nativeBridgeBinding(session) == nil,
           remoteObservedScreens[id].map({ Date().timeIntervalSince($0.observedAt) < 10 }) != true {
            throw RemoteHTTPError(409, "원래 편집기 세션의 식별자를 확인하지 못했습니다. Bridge를 업데이트하고 Mac에서 원래 터미널을 선택해주세요.")
        }
        let identity = nativeIdentity(session)
        guard try await Task.detached(operation: identity).value else { throw RemoteHTTPError(409, "원래 CLI의 PID 또는 TTY가 바뀌었습니다. 목록을 새로고침해주세요.") }
        let renderWindow = object["view"] as? String == "screen"
        if renderWindow, let capture = nativeWindowCapture(for: session) { capture.requestPermissions() }
        if let host = ScreenHost(kind: session.terminal), host != .pty { await connectScreenHost(host) }
        guard let current = sessions[id], current.pid == session.pid, current.started == session.started,
              current.tty == session.tty, current.terminal == session.terminal,
              current.bridgeID == session.bridgeID, current.terminalID == session.terminalID,
              try await Task.detached(operation: identity).value else { throw RemoteHTTPError(409, "권한을 확인하는 동안 원래 CLI가 바뀌었습니다. 다시 선택해주세요.") }
        if let binding = nativeBridgeBinding(current) { try await revealNativeBridge(binding, renderWindow: renderWindow) }
        else if let host = ScreenHost(kind: current.terminal), let adapter = screenAdapters[host] {
            let target = ScreenTarget(tty: current.tty, handle: current.screenHandle), show = adapter.reveal
            _ = try await Task.detached { try show(target) }.value
        } else { _ = try await reveal(current) }
        guard let revealed = sessions[id], revealed.phase != .ended,
              revealed.pid == session.pid, revealed.started == session.started, revealed.tty == session.tty,
              revealed.terminal == session.terminal, revealed.orcaHandle == session.orcaHandle,
              revealed.tmuxHandle == session.tmuxHandle,
              revealed.bridgeID == session.bridgeID, revealed.terminalID == session.terminalID,
              try await Task.detached(operation: identity).value else { throw RemoteHTTPError(409, "원래 CLI가 종료되거나 바뀌었습니다. 목록을 새로고침해주세요.") }
        if renderWindow { nativeWindowCapture(for: revealed)?.invalidate() }
        invalidateRemoteRead(id)
        return try await remoteTerminal(sessionID: id, realtime: true, renderWindow: renderWindow)
    }
    private func revealNativeBridge(_ binding: NativeBridgeBinding, renderWindow: Bool = false) async throws {
        guard let peer = peers[binding.peerID] else { throw RemoteHTTPError(409, "원래 편집기 창 연결이 끊겼습니다.") }
        let actionID = UUID().uuidString
        let generation: String? = try await withCheckedThrowingContinuation { continuation in
            remoteRevealReplies[actionID] = (binding.peerID, binding.terminalID, continuation)
            var message: JSONObject = ["method": "reveal", "native": true, "terminalID": binding.terminalID, "id": actionID,
                "generation": binding.generation, "expiresAt": Date().addingTimeInterval(5).timeIntervalSince1970 * 1000]
            if renderWindow { message["view"] = "screen" }
            guard peer.send(message) else {
                remoteRevealReplies.removeValue(forKey: actionID)?.continuation.resume(throwing: RemoteHTTPError(409, "원래 편집기 창 연결이 끊겼습니다.")); return
            }
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                self?.remoteRevealReplies.removeValue(forKey: actionID)?.continuation.resume(throwing: RemoteHTTPError(409, "원래 편집기 터미널을 표시했는지 확인하지 못했습니다. Mac에서 같은 창과 터미널을 선택해주세요."))
            }
        }
        guard let generation, let current = bridges[binding.peerID]?.first(where: { $0["id"] as? String == binding.terminalID }),
              current["nativeGeneration"] as? String == generation, current["selected"] as? Bool == true,
              !renderWindow || (current["nativeWindowVersion"] as? Int ?? 0) >= 2,
              !renderWindow || bridges[binding.peerID]?.filter({ $0["name"] as? String == binding.terminalName }).count == 1,
              current["ownerPID"] as? Int == Int(binding.ownerPID), current["windowToken"] as? String == binding.windowToken,
              current["name"] as? String == binding.terminalName,
              bridgeOwnerBundle(binding.ownerPID) == binding.ownerBundleID else {
            throw RemoteHTTPError(409, "원래 편집기 창과 터미널의 선택을 확인하지 못했습니다. Mac에서 같은 터미널을 선택해주세요.")
        }
    }

    public func remoteTerminal(sessionID: String, realtime: Bool = false, renderWindow: Bool = false) async throws -> RemoteTerminalFrame {
        guard let session = sessions[sessionID], session.phase != .ended else { throw RemoteHTTPError(409, "화면 연결이 없습니다. Mac의 연결 설정을 확인해주세요.") }
        let sourceCapture = [.terminal, .iterm].contains(session.terminal) ? nativeWindowCapture(for: session) : nil
        let capture = renderWindow ? sourceCapture ?? nativeWindowCapture(for: session) : nil
        let orcaMode = usesOrcaSnapshot(session)
        guard remoteCanRead(session) || sourceCapture != nil || capture != nil || orcaMode else { throw RemoteHTTPError(409, "화면 연결이 없습니다. Mac의 연결 설정을 확인해주세요.") }
        let hasFreshVT = remoteObservedScreens[sessionID].map { Date().timeIntervalSince($0.observedAt) < 10 } == true
        let nativeBinding = nativeBridgeBinding(session)
        let nativeOnly = session.terminal == .vscode && !hasFreshVT && nativeBinding != nil
        var nativeDisplay: TerminalNativeDisplay?
        if let capture {
            if let binding = session.terminal == .vscode ? nativeBinding : nil, !binding.selected {
                nativeDisplay = TerminalNativeDisplay(state: .inactive, message: "Mac에서 원래 편집기 창과 터미널을 선택하거나 연결 버튼으로 같은 터미널을 표시해주세요.")
            } else if remoteCanRead(session) || verifiedWindowCaptures[sessionID] != nil {
                do {
                    nativeDisplay = try await capture.read(TerminalCaptureTarget(pid: session.pid, started: session.started, tty: session.tty, agent: session.agent), validateIdentity: nativeIdentity(session))
                } catch {
                    try Task.checkCancellation()
                    let identity = nativeIdentity(session)
                    guard try await Task.detached(operation: identity).value else {
                        throw RemoteHTTPError(409, "원래 CLI의 PID 또는 TTY가 바뀌었습니다. 목록을 새로고침해주세요.")
                    }
                    nativeDisplay = TerminalNativeDisplay(state: .unavailable,
                        message: "원래 창 미리보기를 읽지 못했습니다. " + String(error.localizedDescription.prefix(1000)))
                }
            } else {
                nativeDisplay = capture.permissionState() ?? TerminalNativeDisplay(state: .unavailable, message: "연결 버튼을 눌러 Mac의 원래 터미널 화면을 연결해주세요.")
            }
        } else if renderWindow {
            nativeDisplay = TerminalNativeDisplay(state: .unavailable, message: "선택한 원본 터미널의 정확한 앱 창을 확인하지 못했습니다. 일반 터미널의 출력과 입력은 계속 사용할 수 있습니다.")
        } else { nativeDisplay = nil }
        // Permissions can change while a native capture is pending. Preflight
        // again before the legacy Apple-event path, without requesting consent.
        let automationBlocked = [.terminal, .iterm].contains(session.terminal) && sourceCapture?.nonpromptAutomationGranted == false
        if automationBlocked {
            if renderWindow { nativeDisplay = capture?.permissionState() ?? TerminalNativeDisplay(state: .permissionRequired, message: "Mac에서 원래 터미널의 자동화 권한을 허용한 뒤 연결해주세요.") }
        }
        let raw: String, generation: String, observedAt: Date, appearance: TerminalAppearance?, cursor: TerminalCursor?
        var orcaBinding: RemoteOrcaBinding?, sourceReason: String?, outputReason: String?
        if orcaMode {
            let observed: RemoteObservedScreen?
            if !remoteCanRead(session) {
                sourceReason = "연결 버튼을 눌러 Mac의 원래 Orca 터미널 화면을 연결해주세요. 새 터미널은 만들지 않습니다."
                observed = nil
            } else {
                do { observed = try await readOrcaScreen(session, realtime: realtime) }
                catch let error as RemoteHTTPError where error.status == 409 { throw error }
                catch {
                    try Task.checkCancellation()
                    sourceReason = "Orca 원본 ANSI 화면이 연결되지 않았습니다. " + String(error.localizedDescription.prefix(1000))
                    observed = nil
                }
            }
            if let observed {
                raw = observed.raw; generation = observed.generation; observedAt = observed.observedAt
                appearance = observed.appearance; cursor = observed.cursor; orcaBinding = observed.orcaBinding
            } else {
                raw = ""; generation = remoteGeneration(session, host: .orca) + ":ansi:unavailable"; observedAt = Date()
                appearance = nil; cursor = nil
                outputReason = sourceReason
                if renderWindow { nativeDisplay = TerminalNativeDisplay(state: .unavailable, message: sourceReason) }
            }
        } else if automationBlocked, let host = ScreenHost(kind: session.terminal) {
            raw = ""; generation = remoteGeneration(session, host: host) + ":automation-required"; observedAt = Date(); appearance = nil; cursor = nil
            sourceReason = "Mac에서 원래 터미널의 자동화 권한을 허용한 뒤 연결해주세요. 읽기 요청은 권한을 요청하지 않습니다."
            outputReason = sourceReason
        } else if nativeOnly, let binding = nativeBinding {
            raw = ""; generation = nativeBridgeGeneration(binding); observedAt = Date(); appearance = nil; cursor = nil
            outputReason = "Bridge가 연결되기 전의 기존 터미널 출력은 읽을 수 없습니다. 선택한 Mac 원본 터미널에 실시간 키 입력은 그대로 전달할 수 있습니다."
            if !binding.selected { sourceReason = "Mac에서 원래 편집기 창과 터미널을 선택하거나 연결 버튼으로 같은 터미널을 표시해주세요." }
        } else if !remoteCanRead(session), let host = ScreenHost(kind: session.terminal), sourceCapture != nil || nativeDisplay != nil {
            raw = ""; generation = remoteGeneration(session, host: host); observedAt = Date(); appearance = nil; cursor = nil
            outputReason = "연결 버튼을 눌러 원래 터미널의 출력과 입력을 연결해주세요. 새 터미널은 만들지 않습니다."
        } else if let host = ScreenHost(kind: session.terminal), let adapter = screenAdapters[host] {
            let observed = try await readRemoteScreen(session, host: host, adapter: adapter, realtime: realtime)
            raw = observed.raw; generation = observed.generation; observedAt = observed.observedAt
            appearance = observed.appearance; cursor = observed.cursor
        } else {
            guard let observed = remoteObservedScreens[sessionID], Date().timeIntervalSince(observed.observedAt) < 10 else { throw RemoteHTTPError(409, "최신 터미널 화면을 받지 못했습니다. VS Code 연결을 확인해주세요.") }
            raw = observed.raw; generation = observed.generation; observedAt = observed.observedAt
            appearance = observed.appearance; cursor = observed.cursor
        }
        guard let current = sessions[sessionID], current.phase != .ended, current.tty == session.tty,
              current.pid == session.pid, current.started == session.started, current.terminal == session.terminal,
              current.orcaHandle == session.orcaHandle, current.bridgeID == session.bridgeID, current.terminalID == session.terminalID,
              current.tmuxHandle == session.tmuxHandle,
              !nativeOnly || nativeBridgeBinding(current) == nativeBinding,
              remoteCanRead(current) || sourceCapture != nil || capture != nil || usesOrcaSnapshot(current) else { throw RemoteHTTPError(409, "세션 연결이 바뀌었습니다. 목록을 새로고침해주세요.") }
        // Reading the same screen in another browser must not invalidate an input draft.
        // An actual screen/generation change or a consumed frame gets a new token.
        let previous = remoteFrames[sessionID]
        let screen = String(raw.suffix(160_000)), visibleAppearance = screen == raw ? appearance : nil
        let visibleCursor = screen == raw ? cursor : nil
        let token = previous?.raw == raw && previous?.generation == generation && previous?.frame.appearance == visibleAppearance && previous?.frame.cursor == visibleCursor && previous?.frame.nativeDisplay == nativeDisplay && previous?.frame.outputReason == outputReason ? previous!.frame.revision : UUID().uuidString
        let inputIdentity = [.terminal, .tmux].contains(current.terminal) ? terminalInputIdentity(current.pid) : nil
        if let inputIdentity, inputIdentity.pid != current.pid || inputIdentity.processStart != current.started {
            throw RemoteHTTPError(409, "원래 CLI의 실행 식별자가 바뀌었습니다. 목록을 새로고침해주세요.")
        }
        // Presentation generations (for example Automation availability) may
        // rotate stream tokens, but must never replace the original lifetime.
        if let stream = remoteStreams[sessionID] {
            guard stream.identity == nil && inputIdentity == nil || stream.identity.map({ inputIdentity?.sameProcess(as: $0) == true }) == true else {
                throw RemoteHTTPError(409, "원래 CLI의 실행 시각이나 TTY가 바뀌었습니다. 입력하지 않았습니다.")
            }
        }
        if remoteStreams[sessionID]?.generation != generation {
            remoteStreams[sessionID] = (generation, UUID().uuidString, remoteStreams[sessionID]?.identity ?? inputIdentity)
        }
        let registration = current.bridgeID.flatMap { bridges[$0] }?.first { $0["id"] as? String == current.terminalID }
        let relaySupported = !automationBlocked && (!orcaMode || orcaBinding != nil) && (nativeOnly ? nativeBinding?.selected == true : current.terminal != .vscode || (registration?["remoteInputVersion"] as? Int ?? 0) >= 3)
        var keys = remoteCanRead(current) ? remoteKeys(current) : []
        if automationBlocked { keys = [] }
        else if orcaMode { keys = orcaBinding != nil ? remoteKeys(current) : [] }
        else if nativeOnly { keys = nativeBinding?.selected == true ? ["characters", "enter", "escape", "interrupt", "up", "down", "left", "right", "backspace", "delete", "home", "end", "tab"] : [] }
        let frame = RemoteTerminalFrame(sessionID: sessionID, screen: screen, revision: token,
            observedAt: observedAt, keys: keys, inputReason: sourceReason ?? remoteInputReason(current), appearance: visibleAppearance,
            cursor: visibleCursor, streamID: relaySupported ? remoteStreams[sessionID]?.token : nil, nativeDisplay: nativeDisplay, outputReason: outputReason)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        guard try encoder.encode(frame).count <= 2_000_000 else { throw RemoteHTTPError(502, "원본 터미널 화면이 너무 큽니다. Mac에서 창 크기를 줄여주세요.") }
        remoteFrames[sessionID] = (frame, raw, generation, orcaBinding, nativeOnly ? nativeBinding : nil)
        return frame
    }

    public func remoteInput(_ object: JSONObject) async throws -> JSONObject {
        let relay = object["relay"] as? Bool == true
        guard !remoteInputStopped, let id = object["sessionID"] as? String, let token = object["revision"] as? String,
              let kind = (object["kind"] as? String).flatMap(RemoteTerminalInput.Kind.init(rawValue:)),
              let session = sessions[id], session.phase != .ended,
              let observed = remoteFrames[id], relay || observed.frame.revision == token,
              Date().timeIntervalSince(observed.frame.observedAt) < 10 else { throw RemoteHTTPError(409, "화면이 오래되었거나 연결이 바뀌었습니다. 최신 화면을 확인하고 다시 입력해주세요.") }
        if relay {
            guard ![.text, .submit].contains(kind), let stream = object["streamID"] as? String,
                  observed.frame.streamID == stream, remoteStreams[id]?.token == stream,
                  remoteStreams[id]?.generation == observed.generation else { throw RemoteHTTPError(409, "터미널 연결이 바뀌었습니다. 최신 화면을 확인해주세요.") }
            if let host = ScreenHost(kind: session.terminal), observed.generation != remoteGeneration(session, host: host) {
                let orcaGeneration = observed.orcaBinding.map { remoteGeneration(session, host: .orca) + ":ansi:" + $0.token }
                guard host == .orca, observed.generation == orcaGeneration else {
                    throw RemoteHTTPError(409, "대상 터미널이 바뀌었습니다. 최신 화면을 확인해주세요.")
                }
            }
        }
        let orcaInput = usesOrcaSnapshot(session)
        var orcaOwnerPID: Int32?
        if orcaInput {
            guard relay, ![.text, .submit].contains(kind), observed.orcaBinding != nil else {
                throw RemoteHTTPError(409, "Orca 원본 ANSI 화면의 실시간 연결을 확인하고 다시 입력해주세요.")
            }
        }
        let nativeBinding = session.terminal == .vscode ? nativeBridgeBinding(session) : nil
        let nativeInput = observed.nativeBinding != nil
        if nativeInput {
            guard relay, ![.text, .submit].contains(kind), nativeBinding == observed.nativeBinding,
                  nativeBinding?.selected == true, observed.generation == nativeBinding.map(nativeBridgeGeneration) else {
                throw RemoteHTTPError(409, "원래 편집기 터미널의 실시간 연결을 확인하고 다시 입력해주세요.")
            }
        }
        if let reason = remoteInputReason(session) { throw RemoteHTTPError(409, reason) }
        guard !remoteInputSessions.contains(id), observed.frame.keys.contains(kind.rawValue) else { throw RemoteHTTPError(409, "다른 입력이 진행 중이거나 지원하지 않는 키입니다. 화면을 확인해주세요.") }
        if !relay && automaticInputBusy(id) { throw RemoteHTTPError(409, "Mac에서 승인 또는 이어서 진행 입력을 전달하고 있습니다. 잠시 뒤 화면을 확인해주세요.") }
        let input = RemoteTerminalInput(kind: kind, text: object["text"] as? String ?? "", relay: relay); try input.validate()
        remoteInputSessions.insert(id)
        defer {
            remoteInputSessions.remove(id); remoteInputUntil[id] = Date().addingTimeInterval(0.8)
            invalidateRemoteRead(id)
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 810_000_000)
                guard let self, !self.remoteInputStopped, !self.userInputHasPriority(id) else { return }
                self.scheduleScreenApproval(id); self.scheduleCapacityResume(id)
            }
        }
        // Reserve user priority before awaiting an approval already being written.
        let deadline = Date().addingTimeInterval(10)
        while automaticInputBusy(id) {
            guard Date() < deadline else { throw RemoteHTTPError(409, "승인 입력이 끝나지 않았습니다. 화면을 확인한 뒤 다시 입력해주세요.") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        if orcaInput {
            guard let snapshotReader = orcaSnapshotReader, let handle = session.orcaHandle, let binding = observed.orcaBinding else {
                throw RemoteHTTPError(409, "원래 Orca 터미널의 세대를 확인하지 못해 입력하지 않았습니다.")
            }
            do {
                let latest = try await snapshotReader(handle)
                try Self.validateOrcaSnapshot(latest)
                guard RemoteOrcaBinding(latest) == binding else { throw OrcaTerminalStreamError.unavailable("원래 PTY의 실행 세대가 바뀌었습니다.") }
                orcaOwnerPID = latest.ownerPID
            } catch {
                throw RemoteHTTPError(409, "원래 Orca 터미널을 다시 확인하지 못해 입력하지 않았습니다. " + String(error.localizedDescription.prefix(1000)))
            }
        }
        let reader = processReader
        let currentRecords: [ProcessRecord]
        if session.terminal == .tmux {
            guard let current = TmuxRelay.currentProcess(pid: session.pid, started: session.started, tty: session.tty, agent: session.agent) else {
                throw RemoteHTTPError(409, "원래 tmux CLI가 종료되거나 입력 대상이 바뀌었습니다. 목록을 새로고침해주세요.")
            }
            currentRecords = [current]
        } else { currentRecords = try await Task.detached { try reader() }.value }
        let tty = session.tty.replacingOccurrences(of: "/dev/", with: "")
        if let orcaOwnerPID, !currentRecords.contains(where: { $0.pid == orcaOwnerPID && $0.tty == tty }) {
            throw RemoteHTTPError(409, "데몬의 원래 PTY 소유 프로세스가 선택한 CLI의 TTY와 달라 입력하지 않았습니다.")
        }
        guard let process = currentRecords.first(where: { $0.pid == session.pid && $0.started == session.started && $0.tty == tty && $0.agent == session.agent }),
              !remoteInputStopped, process.isForeground, let current = sessions[id], current.phase != .ended, remoteInputReason(current) == nil,
              current.pid == session.pid, current.started == session.started, current.tty == session.tty,
              current.terminal == session.terminal, current.orcaHandle == session.orcaHandle,
              current.tmuxHandle == session.tmuxHandle,
              current.bridgeID == session.bridgeID, current.terminalID == session.terminalID,
              !nativeInput || nativeBridgeBinding(current) == nativeBinding,
              !orcaInput || remoteOrcaBindings[id]?.binding == observed.orcaBinding && remoteFrames[id]?.orcaBinding == observed.orcaBinding,
              (relay ? remoteStreams[id]?.token == (object["streamID"] as? String) : remoteFrames[id]?.frame.revision == token) else { throw RemoteHTTPError(409, "대상 CLI나 화면 상태가 바뀌었습니다. 최신 화면을 확인해주세요.") }
        if session.terminal == .terminal, relay || ![.text, .submit, .enter].contains(kind) {
            guard let original = remoteStreams[id]?.identity, let source = terminalInputIdentity(session.pid),
                  source.sameProcess(as: original), source.foregroundGroup == source.processGroup else {
                throw RemoteHTTPError(409, "원래 CLI의 실행 시각, TTY 또는 입력 대상이 바뀌어 입력하지 않았습니다.")
            }
        }
        // Reserve this exact frame before writing. Neither a timeout nor a second click replays it.
        if !relay { remoteFrames.removeValue(forKey: id) }
        invalidateRemoteRead(id)
        let textual = [.text, .submit, .characters].contains(kind)
        var event = AuditEvent(sessionID: id, summary: textual ? String(input.text.prefix(200)) : kind.rawValue,
            outcome: "웹 입력 전달 확인 중", source: "같은 네트워크 웹", context: AuditContext(session: session), request: kind.rawValue, answer: textual ? input.text : kind.rawValue)
        guard log(event) else { throw RemoteHTTPError(409, "입력 내역을 저장하지 못해 전송하지 않았습니다.") }
        do {
            let sent: Bool
            if let host = ScreenHost(kind: session.terminal), let adapter = screenAdapters[host] {
                let job = currentRecords.filter { $0.tty == tty && $0.processGroup == process.processGroup }.map(\.pid)
                let target = ScreenTarget(tty: session.tty, handle: session.screenHandle, jobPIDs: job,
                    sourcePID: session.pid, sourceStarted: session.started, sourceIdentity: remoteStreams[id]?.identity), write = adapter.input
                let result = try await Task.detached { try write(target, observed.raw, session.agent, input) }.value
                sent = result == .sent
            } else if let peerID = session.bridgeID, let peer = peers[peerID], let terminalID = session.terminalID {
                let actionID = UUID().uuidString
                sent = try await withCheckedThrowingContinuation { continuation in
                    remoteInputReplies[actionID] = (peerID, continuation)
                    var message: JSONObject = ["method": "remoteInput", "id": actionID, "terminalID": terminalID,
                        "screen": observed.raw, "generation": nativeInput ? nativeBinding!.generation : String(observed.generation.dropFirst(peerID.count + 1)),
                        "kind": kind.rawValue, "text": input.text, "relay": relay, "expiresAt": Date().addingTimeInterval(2).timeIntervalSince1970 * 1000]
                    if nativeInput { message["native"] = true }
                    guard peer.send(message) else {
                        remoteInputReplies.removeValue(forKey: actionID)?.continuation.resume(throwing: AppError.message("VS Code 연결이 끊겨 전달 결과를 확인하지 못했습니다.")); return
                    }
                    Task { [weak self] in
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        self?.remoteInputReplies.removeValue(forKey: actionID)?.continuation.resume(throwing: AppError.message("입력 전달 결과를 확인하지 못했습니다. 입력을 다시 보내지 말고 화면을 확인해주세요."))
                    }
                }
            } else { sent = false }
            invalidateRemoteRead(id)
            event.outcome = sent ? "웹 입력 전달" : "웹 입력 미전달 · 화면 변경"; _ = log(event)
            guard sent else { throw RemoteHTTPError(409, "현재 화면이나 CLI가 바뀌어 입력하지 않았습니다. 최신 화면을 확인해주세요.") }
            return ["sent": true, "message": "터미널에 입력을 전달했습니다. 화면에서 반영 결과를 확인하세요."]
        } catch {
            if event.outcome == "웹 입력 전달 확인 중" { event.outcome = "웹 입력 결과 미확인"; _ = log(event) }
            throw error
        }
    }

    private func automaticInputBusy(_ id: String) -> Bool {
        automaticInputSessions.contains(id) || capacityStates[id]?.phase == .sending || pendingActions.values.contains { $0.sessionID == id }
    }
    private func userInputHasPriority(_ id: String) -> Bool {
        remoteInputSessions.contains(id) || remoteInputUntil[id].map { Date() < $0 } == true
    }

    public func remoteAction(_ object: JSONObject) async throws -> JSONObject {
        guard let action = object["action"] as? String else { throw RemoteHTTPError(400, "동작을 지정해주세요.") }
        if action == "pause" {
            guard let paused = object["paused"] as? Bool else { throw RemoteHTTPError(400, "일시정지 값을 지정해주세요.") }
            try setPaused(paused); return ["paused": snapshot.paused]
        }
        if action == "questionDelay" {
            guard let seconds = object["seconds"] as? Int else { throw RemoteHTTPError(400, "대기 시간을 지정해주세요.") }
            try setQuestionNotificationDelay(seconds); return ["seconds": snapshot.questionNotificationDelay]
        }
        guard let id = object["sessionID"] as? String, let session = sessions[id], session.phase != .ended else { throw RemoteHTTPError(404, "세션이 종료되었거나 찾을 수 없습니다.") }
        switch action {
        case "automatic":
            guard let enabled = object["enabled"] as? Bool else { throw RemoteHTTPError(400, "자동 승인 값을 지정해주세요.") }
            try setAutomatic(id, enabled: enabled)
        case "reveal": _ = try await reveal(session)
        case "read": try markNotificationsRead(id)
        case "claudeApprove", "claudeRelease":
            guard let request = object["requestIDForApproval"] as? String else { throw RemoteHTTPError(400, "승인 요청을 지정해주세요.") }
            if action == "claudeApprove" { try answerClaudeApproval(sessionID: id, requestID: request) }
            else { try releaseClaudeApproval(sessionID: id, requestID: request) }
        case "replyQuestion":
            guard let question = object["questionID"] as? String, let answer = object["answer"] as? String else { throw RemoteHTTPError(400, "질문과 답변을 지정해주세요.") }
            try await replyToQuestion(sessionID: id, questionID: question, answer: answer)
        case "cancelQuestion":
            guard let question = object["questionID"] as? String else { throw RemoteHTTPError(400, "질문을 지정해주세요.") }
            try cancelQuestionAutomaticReply(sessionID: id, questionID: question)
        case "beginQuestion":
            guard let question = object["questionID"] as? String else { throw RemoteHTTPError(400, "질문을 지정해주세요.") }
            try beginQuestionReply(sessionID: id, questionID: question)
        case "cancelCapacity": cancelCapacityResume(id)
        default: throw RemoteHTTPError(400, "지원하지 않는 동작입니다.")
        }
        return ["ok": true]
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
        projectCapacityResumes()
        reconcileAutomaticQuestionReplies()
        updateQuestionAutomationStates()
        updateInboxes()
        let ranks = Dictionary(uniqueKeysWithValues: sessionOrder.enumerated().map { ($0.element, $0.offset) })
        let presented = presentedSessions().sorted {
            if ($0.phase == .ended) != ($1.phase == .ended) { return $0.phase != .ended }
            let left = ranks[$0.id] ?? Int.max, right = ranks[$1.id] ?? Int.max
            if left != right { return left < right }
            if $0.project != $1.project { return $0.project.localizedStandardCompare($1.project) == .orderedAscending }
            return $0.id < $1.id
        }
        // Heartbeats still reconcile timers and notices, but identical state must
        // not invalidate every SwiftUI window and notification subscription.
        if snapshot.sessions != presented { snapshot.sessions = presented }
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
        defer {
            discovering = false
            if !initialDiscoveryComplete { initialDiscoveryComplete = true }
        }
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
        await refreshScreens()
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

    private func duplicateQuestionIDs(_ questions: [QueuedQuestion]) -> Set<String> {
        var firstIDs: [String: [String: String]] = [:], duplicates = Set<String>()
        for question in questions {
            let title = question.titleIdentity
            if let first = firstIDs[question.threadID]?[title] {
                duplicates.insert(first); duplicates.insert(question.id)
            } else { firstIDs[question.threadID, default: [:]][title] = question.id }
        }
        return duplicates
    }

    private func questionAutomationBlock(_ question: QueuedQuestion, duplicates: Set<String>) -> QuestionAutomation.Phase? {
        if let override = questionAutomationOverrides[question.id] { return override }
        if duplicates.contains(question.id) { return .duplicate }
        if question.hasLaterUserMessage == true { return .needsReview }
        if restoredQuestionIDs.contains(question.id) { return .restored }
        return nil
    }

    private func updateQuestionAutomationStates() {
        for (id, session) in sessions {
            guard let questions = session.queuedQuestions else { continue }
            let duplicates = duplicateQuestionIDs(questions)
            sessions[id]?.queuedQuestions = questions.map { question in
                var question = question
                question.automation = nil
                guard session.phase != .ended, question.reply == nil || question.reply?.phase == .cancelled else { return question }
                if let block = questionAutomationBlock(question, duplicates: duplicates) {
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
                let duplicates = duplicateQuestionIDs(session.questions)
                for var question in session.questions {
                    let pending = automaticQuestionReplies[question.id]
                    // Keep our reservation during preflight, but never automatically retry
                    // a failed, uncertain, queued, or manually submitted response.
                    guard questionAutomationBlock(question, duplicates: duplicates) == nil,
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
        let managed = found.filter { value in
            guard value.agent == .claude || value.agent == .codex else { return false }
            // A discovery read started before close may finish after it. Keep
            // the exact binding while the final screen is retained so that
            // stale records cannot revive that terminated CLI.
            if let id = ptySessionBindings[value.id], let terminal = try? managedPTY.terminal(id), !terminal.isRunning { return false }
            return true
        }.map { value -> AgentSession in
            var session = value
            if let owned = managedPTY.owned(tty: session.tty) {
                session.terminal = .pty; session.hostName = "PTY"; session.hostBundleID = "local.autoapprove.mac"
                ptySessionBindings[session.id] = owned.descriptor.ptyID
            } else { ptySessionBindings.removeValue(forKey: session.id) }
            return session
        }
        let live = Set(managed.map(\.id))
        tmuxRelay.retain(handles: Set(managed.compactMap(\.tmuxHandle)))
        ptySessionBindings = ptySessionBindings.filter { live.contains($0.key) || (try? managedPTY.terminal($0.value).isRunning) == false }
        codexCompletions.retain(sessionIDs: live)
        for var session in managed {
            if var existing = sessions[session.id] {
                existing.tty = session.tty
                if existing.bridgeID == nil { existing.terminal = session.terminal }
                existing.hostName = session.hostName; existing.hostBundleID = session.hostBundleID; existing.orcaHandle = session.orcaHandle
                existing.tmuxHandle = session.tmuxHandle
                session = existing
            }
            if let cwd = directories[session.id], !cwd.isEmpty, session.cwd != cwd {
                session.cwd = cwd; session.gitBranch = nil
            }
            if session.phase == .ended { session.setPhase(.unknown, detail: "새 상태를 확인하고 있습니다."); session.channel = .none; session.automatic = false }
            if sessions[session.id] == nil {
                restorePreferences(&session)
                if let owned = managedPTY.owned(tty: session.tty), ptyAutomatic[owned.descriptor.ptyID] == true {
                    session.automatic = true
                    try? store.set("automatic:\(session.id)", "true")
                }
                session.detail = Self.connectionGuide(session)
            }
            sessions[session.id] = session
        }
        for key in Array(sessions.keys) where key.hasPrefix("process:") && !live.contains(key) {
            sessions[key]?.setPhase(.ended, detail: "프로세스가 종료되었습니다."); sessions[key]?.channel = .none; sessions[key]?.automatic = false
            sessions[key]?.queuedQuestions = []; sessions[key]?.codexQuestionsError = nil
            claudeWorkIDs.removeValue(forKey: key)
            clearScreen(key); capacityStates.removeValue(forKey: key)
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
        synchronizePTYContainers()
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
        if let owned = managedPTY.owned(tty: session.tty) { ptyAutomatic[owned.descriptor.ptyID] = enabled }
        for member in groupIDs(target) { screens[member]?.scheduledID = nil }
        if !enabled { for member in groupIDs(target) { capacityStates.removeValue(forKey: member) } }
        publish()
        if enabled { scheduleScreenApproval(target) }
        Task { await evaluateKeepAwake() }
    }
    public func setPaused(_ paused: Bool) throws {
        snapshot.paused = paused; revision &+= 1
        for id in screens.keys { screens[id]?.scheduledID = nil }
        for id in Array(capacityStates.keys) { capacityStates[id]?.scheduledID = nil }
        try store.set("paused", paused ? "true" : "false")
        if !paused {
            for id in screens.keys { scheduleScreenApproval(id) }
            // A deadline that passed while paused still leaves a moment to cancel.
            for (id, state) in capacityStates where state.phase == .waiting {
                capacityStates[id]?.deadline = max(state.deadline, Date().addingTimeInterval(5))
                scheduleCapacityResume(id)
            }
        }
        publish()
        Task { await evaluateKeepAwake() }
    }
    public func connectTerminal() async { await connectScreenHost(.terminal) }
    public func disconnectTerminal() { disconnectScreenHost(.terminal) }
    public func refreshTerminal() async { await refreshScreenHost(.terminal) }
    /// Hosts poll independently; a slow Orca CLI must not delay Terminal or iTerm2.
    public func refreshScreens() async {
        async let terminal: Void = refreshScreenHost(.terminal)
        async let iterm: Void = refreshScreenHost(.iterm)
        async let orca: Void = refreshScreenHost(.orca)
        async let tmux: Void = refreshScreenHost(.tmux)
        async let pty: Void = refreshScreenHost(.pty)
        _ = await (terminal, iterm, orca, tmux, pty)
    }
    public func connectScreenHost(_ host: ScreenHost) async {
        do { try store.set(Self.enabledKey(host), "true") }
        catch { updateHealth(host) { $0.status = "연결 설정 저장 실패: \(error.localizedDescription)" }; return }
        screenConnections[host, default: ScreenConnection()].enabled = true
        screenConnections[host]?.permissionBlocked = false; screenConnections[host]?.retryAfter = .distantPast
        updateHealth(host) { $0.requested = true; $0.status = "연결 확인 중…" }
        await refreshScreenHost(host); publish()
    }
    public func disconnectScreenHost(_ host: ScreenHost) {
        screenConnections[host]?.enabled = false; revision &+= 1
        if host == .tmux { tmuxRelay.stop() }
        for id in sessions.keys where sessions[id]?.terminal == host.kind {
            remoteScreenReads.removeValue(forKey: id)?.task.cancel(); remoteFrames.removeValue(forKey: id)
        }
        updateHealth(host) { $0.status = "연결 해제됨"; $0.requested = false; $0.connected = false }
        do { try store.set(Self.enabledKey(host), "false") }
        catch { updateHealth(host) { $0.status = "연결은 해제했지만 설정을 저장하지 못했습니다: \(error.localizedDescription)" } }
        for id in Array(sessions.keys) where sessions[id]?.channel == host.channel {
            sessions[id]?.channel = .none; sessions[id]?.setPhase(.unknown, detail: "\(host.title) 연결이 해제되어 현재 상태를 확인할 수 없습니다."); clearScreen(id)
            capacityStates.removeValue(forKey: id)
        }
        publish()
    }
    public func refreshScreenHost(_ host: ScreenHost) async {
        guard let connection = screenConnections[host], connection.enabled, !connection.polling, !connection.permissionBlocked,
              Date() >= connection.retryAfter, let adapter = screenAdapters[host] else { return }
        screenConnections[host]?.polling = true; updateHealth(host) { $0.connecting = true }
        defer { screenConnections[host]?.polling = false; updateHealth(host) { $0.connecting = false } }
        let targets = sessions.values.filter { $0.agent != .shell && $0.terminal == host.kind && $0.phase != .ended }
        let title = host.title
        do {
            let requests = targets.map { ScreenTarget(tty: $0.tty, handle: $0.screenHandle) }
            let reader = adapter.screens
            let result = try await Task.detached(priority: .utility) { try reader(requests) }.value
            guard screenConnections[host]?.enabled == true else { return }
            let targets = targets.filter { target in
                guard let current = sessions[target.id], current.phase != .ended,
                      current.pid == target.pid, current.started == target.started,
                      current.tty == target.tty, current.terminal == host.kind else { return false }
                if host == .pty {
                    guard let id = ptySessionBindings[target.id], (try? managedPTY.terminal(id).isRunning) == true else { return false }
                }
                return true
            }
            let connected = targets.filter { target in result.screens.contains { $0.tty == target.tty } }.count
            let missing = targets.count - connected
            updateHealth(host) { health in
                health.connected = connected > 0 || targets.isEmpty
                if connected > 0 {
                    health.status = "연결됨 · \(connected)개 세션" + (missing > 0 ? " · \(missing)개 탭 확인 필요" : "")
                } else if targets.isEmpty {
                    health.status = "연결됨 · \(title)에서 실행 중인 CLI 세션 없음"
                } else {
                    health.status = "해당 세션의 \(title) 탭을 읽지 못했습니다. " + (result.failures.first?.message ?? "닫힌 탭인지 확인한 후 다시 연결해주세요.")
                }
            }
            for target in targets {
                guard let screen = result.screens.first(where: { $0.tty == target.tty }) else {
                    if sessions[target.id]?.channel != .hook {
                        sessions[target.id]?.channel = .none
                        sessions[target.id]?.setPhase(.unknown, detail: "현재 \(title) 화면을 읽지 못했습니다.")
                        sessions[target.id]?.pendingSummary = nil
                        sessions[target.id]?.detail = "이 세션의 \(title) 탭을 읽지 못했습니다. " + (result.failures.first(where: { $0.tty == target.tty })?.message ?? "탭이 열려 있는지 확인해주세요.")
                        clearScreen(target.id)
                    }
                    continue
                }
                sessions[target.id]?.terminalTitle = screen.title
                if sessions[target.id]?.channel != .hook || sessions[target.id]?.pendingInTerminal == true {
                    if sessions[target.id]?.channel != .hook { sessions[target.id]?.channel = host.channel }
                    sessions[target.id]?.detail = "화면의 실행 권한 확인을 감지합니다. 일반 질문은 직접 답해주세요."
                    receiveScreen(sessionID: target.id, raw: screen.contents, generation: "\(host.rawValue):\(target.id)", source: host.channel, appearance: screen.appearance)
                }
            }
        } catch {
            // Denied Automation stays blocked until the user reconnects; other failures retry.
            let blocked = error is TerminalAdapterError
            screenConnections[host]?.permissionBlocked = blocked
            screenConnections[host]?.retryAfter = Date().addingTimeInterval(5)
            updateHealth(host) { $0.connected = false; $0.status = error.localizedDescription + (blocked ? "" : " · 자동 재연결 대기") }
            for id in Array(sessions.keys) where sessions[id]?.channel == host.channel && sessions[id]?.phase != .ended {
                sessions[id]?.channel = .none; sessions[id]?.setPhase(.unknown, detail: "\(title) 연결이 끊겨 현재 상태를 확인할 수 없습니다."); clearScreen(id)
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
        if let host = ScreenHost(kind: current.terminal), let adapter = screenAdapters[host] {
            let target = ScreenTarget(tty: current.tty, handle: current.screenHandle), reveal = adapter.reveal
            return try await Task.detached { try reveal(target) }.value
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
            case "web":
                if let enabled = params["enabled"] as? Bool {
                    let port = (params["port"] as? Int).flatMap(UInt16.init(exactly:))
                    try setWebEnabled(enabled, port: port)
                }
                result = try JSONSerialization.jsonObject(with: JSONEncoder().encode(webStatus)) as? JSONObject ?? [:]
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
                peers[peer.id] = peer
                // Each VS Code window sends this every two seconds, including
                // windows without a managed CLI. Discovery separately rematches
                // saved registrations when a new process appears.
                if bridges[peer.id].map({ NSArray(array: $0).isEqual(to: terminals) }) != true {
                    bridges[peer.id] = terminals
                    matchBridge(peer.id, terminals: terminals)
                    let status = "연결됨 · \(bridges.count)개 창"
                    if snapshot.health.vscode != status { snapshot.health.vscode = status }
                    publish()
                }
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
                var channelChanged = false
                let appearance = TerminalAppearance.decode(params["appearance"], screen: screen)
                let cursor = TerminalCursor.decode(params["cursor"], screen: screen)
                for id in Array(sessions.keys) where sessions[id]?.agent != .shell && sessions[id]?.phase != .ended && sessions[id]?.bridgeID == peer.id && sessions[id]?.terminalID == terminalID {
                    channelChanged = channelChanged || (sessions[id]?.channel != .hook && sessions[id]?.channel != .vscodeScreen)
                    if sessions[id]?.channel != .hook { sessions[id]?.channel = .vscodeScreen }
                    receiveScreen(sessionID: id, raw: screen, generation: peer.id + ":" + generation, source: .vscodeScreen, appearance: appearance, cursor: cursor)
                }
                // receiveScreen publishes accepted observations itself. Ordinary
                // terminal output must not recalculate unrelated CLI questions.
                if channelChanged { publish() }
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
            case "remoteInputResult":
                if let id = params["actionID"] as? String, let pending = remoteInputReplies[id], pending.peerID == peer.id {
                    remoteInputReplies.removeValue(forKey: id)
                    pending.continuation.resume(returning: params["success"] as? Bool == true)
                }
            case "revealResult":
                if let id = params["actionID"] as? String, let pending = remoteRevealReplies[id], pending.peerID == peer.id,
                   params["terminalID"] as? String == pending.terminalID {
                    remoteRevealReplies.removeValue(forKey: id)
                    let generation = params["nativeGeneration"] as? String
                    pending.continuation.resume(returning: params["success"] as? Bool == true && (generation?.utf8.count ?? 0) <= 256 ? generation : nil)
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
        guard !terminals.isEmpty else { return }
        let byPID = Dictionary(records.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        for id in Array(sessions.keys) where sessions[id]?.phase != .ended {
            guard let session = sessions[id] else { continue }
            let tty = session.tty.replacingOccurrences(of: "/dev/", with: "")
            let ancestry = Set(ProcessDiscovery.ancestors(of: session.pid, byPID: byPID).prefix { $0.tty == "??" || $0.tty == tty }.map(\.pid))
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
        // Status clients and Claude helpers are short-lived socket connections,
        // not VS Code bridges. Their close cannot change bridge/session state.
        guard peers.removeValue(forKey: peerID) != nil else { return }
        bridges.removeValue(forKey: peerID)
        for id in Array(remoteInputReplies.keys) where remoteInputReplies[id]?.peerID == peerID {
            remoteInputReplies.removeValue(forKey: id)?.continuation.resume(throwing: AppError.message("VS Code 연결이 끊겼습니다. 입력을 다시 보내지 말고 화면을 확인해주세요."))
        }
        for id in Array(remoteRevealReplies.keys) where remoteRevealReplies[id]?.peerID == peerID {
            remoteRevealReplies.removeValue(forKey: id)?.continuation.resume(throwing: AppError.message("원래 편집기 창 연결이 끊겼습니다."))
        }
        for id in Array(bridgeWindowCaptures.keys) where bridgeWindowCaptures[id]?.binding.peerID == peerID {
            bridgeWindowCaptures.removeValue(forKey: id)?.capture.invalidate()
        }
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
        remoteObservedScreens.removeValue(forKey: id); remoteFrames.removeValue(forKey: id); remoteScreenReads.removeValue(forKey: id)?.task.cancel()
        if sessions[id] == nil || sessions[id]?.phase == .ended { remoteOrcaBindings.removeValue(forKey: id) }
        screens.removeValue(forKey: id); activityTrackers.removeValue(forKey: id); screenObservedAt.removeValue(forKey: id)
        sessions[id]?.pendingSummary = nil; sessions[id]?.pendingInTerminal = false
        sessions[id]?.pendingRequestID = nil
    }

    public func receiveScreen(sessionID: String, raw: String, generation: String, source: ApprovalChannel? = nil, at now: Date = Date(), appearance: TerminalAppearance? = nil, cursor: TerminalCursor? = nil) {
        guard let session = sessions[sessionID], session.agent != .shell, session.phase != .ended else { return }
        remoteObservedScreens[sessionID] = RemoteObservedScreen(raw: raw, generation: generation, observedAt: now, appearance: appearance?.validated(for: raw), cursor: cursor?.validated(for: raw))
        // The original hook is still waiting in this app; screen input would be a second response path.
        guard !liveClaudeHooks.values.contains(where: { $0.request.sessionID == sessionID }) else { return }
        // A parked main terminal renders the child PTY. Its pixels cannot identify
        // which child owns the prompt; the child's hook is the response channel.
        guard !hasBackgroundChildren(sessionID), claudeParents[sessionID] == nil else { return }
        let prompt = PromptDetector.detect(raw, agent: session.agent)
        if session.channel == .hook {
            // A hook that already allowed the request must never be followed by a screen approval.
            guard session.phase == .approval, session.pendingInTerminal, prompt != nil,
                  let source, source.isScreen else { return }
            sessions[sessionID]?.channel = source
        } else if !session.channel.isScreen { return }
        defer { publish() }
        screenObservedAt[sessionID] = now
        if session.agent == .codex { observeCapacity(sessionID, raw: raw, at: now) }
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
            presentPhase(sessionID, activity, at: now)
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

    // MARK: Codex capacity stops

    /// Answers a capacity stop only for a screen-connected Codex session with auto-approval on.
    /// After a confirmed send, the next stop drawn is the next failure of the same run.
    private func observeCapacity(_ id: String, raw: String, at now: Date) {
        guard let session = sessions[id], session.agent == .codex, session.phase != .ended else { return }
        guard session.automatic, session.channel.isScreen else { capacityStates.removeValue(forKey: id); return }
        let stop = CodexCapacityStop.detect(raw, agent: .codex)
        if var state = capacityStates[id] {
            if let stop {
                state.observedAt = now
                switch state.phase {
                case .sending:
                    capacityStates[id] = state
                case .sent:
                    // The send was verified, so a stop drawn afterwards is the next failure of this run.
                    // Repeated failures can fill the screen until it looks unchanged.
                    let elapsed = now.timeIntervalSince(state.sentAt ?? now)
                    if stop.identity != state.stop.identity || elapsed >= capacityStaleFrameWindow {
                        let attempt = elapsed >= capacityProgressWindow ? 1 : state.attempt + 1
                        startCapacityRun(id, stop: stop, channel: session.channel, attempt: attempt, at: now)
                    } else {
                        capacityStates[id] = state
                    }
                case .waiting, .unavailable, .review, .exhausted, .cancelled:
                    if stop.identity != state.stop.identity {
                        // Not ours: someone continued by hand, or the transcript was redrawn.
                        startCapacityRun(id, stop: stop, channel: session.channel, attempt: 1, at: now)
                    } else {
                        state.stop = stop; capacityStates[id] = state
                        if state.phase == .waiting, state.scheduledID == nil { scheduleCapacityResume(id) }
                    }
                }
            } else {
                let phase = ActivityDetector.detect(raw, agent: .codex).phase
                switch state.phase {
                case .sending: break
                case .sent:
                    let elapsed = now.timeIntervalSince(state.sentAt ?? now)
                    if elapsed > 10, CodexResumeCheck.draftVisible(raw, text: CodexCapacityStop.resumeText) {
                        capacityStates[id]?.phase = .review
                    } else if phase == .idle || (phase != .unknown && elapsed >= capacityProgressWindow) {
                        // Ended normally, or kept working: the run of failures is over.
                        capacityStates.removeValue(forKey: id)
                    }
                case .review where CodexResumeCheck.draftVisible(raw, text: CodexCapacityStop.resumeText):
                    break // Our unsent text still waits in the composer for the user.
                case .waiting, .unavailable, .review, .exhausted, .cancelled:
                    // The user typed or a turn is running. A partial repaint keeps the stop.
                    if phase != .unknown || CodexResumeCheck.composerChanged(raw, region: state.stop.region) {
                        capacityStates.removeValue(forKey: id)
                    }
                }
            }
        } else if let stop {
            startCapacityRun(id, stop: stop, channel: session.channel, attempt: 1, at: now)
        }
    }

    /// One phase per frame: a stopped turn shows as such, and asks for attention only once automation gave up.
    private func presentPhase(_ id: String, _ activity: ActivityObservation, at now: Date) {
        guard let state = capacityStates[id], state.phase != .sent else {
            sessions[id]?.setPhase(activity.phase, detail: activity.detail, at: now, monitoring: activity.monitoring)
            return
        }
        let detail = "모델 용량 부족으로 Codex 작업이 멈췄습니다."
        guard state.phase == .review || state.phase == .exhausted else {
            sessions[id]?.setPhase(activity.phase, detail: detail, at: now, monitoring: activity.monitoring)
            return
        }
        sessions[id]?.setPhase(.input, detail: detail, at: now)
        sessions[id]?.pendingSummary = state.phase == .review
            ? "이어서 진행 요청을 입력했지만 전송을 확인하지 못했습니다. 터미널에서 Codex 입력창을 확인해주세요."
            : "모델 용량 부족이 계속되어 자동으로 \(capacityResumeDelays.count)회 이어서 진행한 뒤 멈췄습니다. 터미널에서 이어서 진행해주세요."
        sessions[id]?.pendingInTerminal = true
        sessions[id]?.pendingRequestID = "capacity:\(state.phase == .review ? "review" : "exhausted"):\(state.stop.identity)"
    }

    private func startCapacityRun(_ id: String, stop: CodexCapacityStop, channel: ApprovalChannel, attempt: Int, at now: Date) {
        let delays = capacityResumeDelays
        var state = CapacityState(phase: .waiting, stop: stop, channel: channel, attempt: min(attempt, delays.count),
            deadline: now, observedAt: now)
        // VS Code sessions have no typing path for this yet.
        if ScreenHost(channel: channel).flatMap({ screenAdapters[$0] }) == nil {
            state.phase = .unavailable
        } else if attempt > delays.count {
            state.phase = .exhausted
        } else {
            state.deadline = now.addingTimeInterval(delays[attempt - 1])
        }
        capacityStates[id] = state
        if state.phase == .waiting { scheduleCapacityResume(id) }
    }

    private func scheduleCapacityResume(_ id: String) {
        guard let state = capacityStates[id], state.phase == .waiting, state.scheduledID == nil, !snapshot.paused, !userInputHasPriority(id), !automaticInputBusy(id) else { return }
        let scheduledID = UUID(), scheduledRevision = revision
        capacityStates[id]?.scheduledID = scheduledID
        let delay = max(0, state.deadline.timeIntervalSinceNow)
        Task { [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            await self?.dispatchCapacityResume(id, scheduledID: scheduledID, revision: scheduledRevision)
        }
    }

    private func dispatchCapacityResume(_ id: String, scheduledID: UUID, revision scheduledRevision: UInt64) async {
        func current() -> (CapacityState, AgentSession, ScreenHostAdapter, ScreenHost)? {
            guard let state = capacityStates[id], state.scheduledID == scheduledID, state.phase == .waiting,
                  revision == scheduledRevision, !snapshot.paused, !userInputHasPriority(id), !automaticInputBusy(id), let session = sessions[id], session.automatic,
                  session.phase != .ended, session.channel == state.channel, let host = ScreenHost(channel: state.channel),
                  let adapter = screenAdapters[host], Date() >= state.deadline,
                  Date().timeIntervalSince(state.observedAt) < 6 else { return nil }
            return (state, session, adapter, host)
        }
        guard current() != nil else {
            // A later frame reschedules a stop that is still visible.
            if capacityStates[id]?.scheduledID == scheduledID { capacityStates[id]?.scheduledID = nil }
            return
        }
        let reader = processReader
        let live = try? await Task.detached(priority: .utility) { try reader() }.value
        guard let (state, session, adapter, host) = current(),
              let process = live?.first(where: { $0.pid == session.pid && $0.started == session.started && $0.agent == .codex
                  && "/dev/" + $0.tty == session.tty }), process.isForeground else {
            if capacityStates[id]?.scheduledID == scheduledID { capacityStates[id]?.scheduledID = nil }
            return
        }
        capacityStates[id]?.phase = .sending; capacityStates[id]?.scheduledID = nil
        var event = AuditEvent(sessionID: id, summary: "모델 용량 부족 · 이어서 진행 요청 (\(state.attempt)/\(capacityResumeDelays.count))",
            outcome: "이어서 진행 요청 · 결과 미확인", source: "\(host.title) 화면", context: AuditContext(session: session),
            request: state.stop.region, answer: CodexCapacityStop.resumeText)
        // Persist the attempt before typing; a crash or lost result remains traceable.
        guard log(event) else { capacityStates[id]?.phase = .review; publish(); return }
        publish()
        let job = (live ?? []).filter { $0.tty == process.tty && $0.processGroup == process.processGroup }.map(\.pid)
        let target = ScreenTarget(tty: session.tty, handle: session.screenHandle, jobPIDs: job,
            sourcePID: session.pid, sourceStarted: session.started)
        let resume = adapter.resume, region = state.stop.region, text = CodexCapacityStop.resumeText
        automaticInputSessions.insert(id)
        defer { automaticInputSessions.remove(id) }
        do {
            let delivery = try await Task.detached { try resume(target, region, text) }.value
            switch delivery {
            case .sent:
                event.outcome = "이어서 진행 요청 전달"
                capacityStates[id]?.phase = .sent; capacityStates[id]?.sentAt = Date(); capacityStates[id]?.unsent = 0
            case .typed:
                // Typed, but neither a draft nor a new message was visible: never type again.
                event.outcome = "입력 확인 필요 · 이어서 진행 전송 미확인"
                capacityStates[id]?.phase = .review
            case .screenChanged, .missingTarget, .agentMissing:
                // Nothing was typed. Try again on a fresh frame, a few times.
                event.outcome = "입력 미전달 · 새 화면 확인 (\(delivery.rawValue))"
                let unsent = (capacityStates[id]?.unsent ?? 0) + 1
                capacityStates[id]?.unsent = unsent
                capacityStates[id]?.phase = unsent >= 3 ? .review : .waiting
                capacityStates[id]?.deadline = Date().addingTimeInterval(capacityUnsentRetryDelay)
            }
        } catch {
            // The write may have happened; an uncertain input is never repeated.
            event.outcome = "입력 확인 필요: \(error.localizedDescription)"
            capacityStates[id]?.phase = .review
        }
        log(event)
        publish()
    }

    public func cancelCapacityResume(_ id: String) {
        guard let phase = capacityStates[id]?.phase, phase == .waiting || phase == .unavailable else { return }
        capacityStates[id]?.phase = .cancelled; capacityStates[id]?.scheduledID = nil
        publish()
    }

    // MARK: Keeping the Mac awake with the lid closed

    static let keepAwakeOff = "꺼져 있습니다. 덮개를 닫으면 평소처럼 잠듭니다."
    static let keepAwakeChecking = "관리자 권한 규칙을 확인하고 있습니다."

    /// Turning it on installs the sudo rule first when it is missing, which asks for an administrator password.
    public func setKeepAwake(_ enabled: Bool) async throws {
        if enabled {
            let control = powerControl
            if !(await Task.detached(priority: .userInitiated) { control.ruleInstalled() }.value) {
                try await Task.detached(priority: .userInitiated) { try control.installRule() }.value
                guard await Task.detached(priority: .userInitiated, operation: { control.ruleInstalled() }).value else {
                    throw AppError.message("권한 규칙을 설치했지만 확인하지 못했습니다. 다시 시도해주세요.")
                }
            }
            keepAwakeRule = true
        }
        try store.set("keepAwake", enabled ? "true" : "false")
        keepAwakeEnabled = enabled
        keepAwakeFailure = nil; keepAwakeRetryAfter = .distantPast
        await evaluateKeepAwake()
    }

    /// Turns the setting off and releases a hold first, then removes the rule with an administrator password.
    public func removeKeepAwakeRule() async throws {
        if keepAwakeEnabled { try await setKeepAwake(false) }
        guard !keepAwakeSwitch.owned else { throw AppError.message("잠자기 금지를 먼저 해제하지 못했습니다. 잠시 후 다시 시도해주세요.") }
        let control = powerControl
        try await Task.detached(priority: .userInitiated) { try control.removeRule() }.value
        keepAwakeRule = nil
        await evaluateKeepAwake()
    }

    /// The keep-awake timer calls this every few seconds, and changes that affect it call it at once.
    /// A call during a check waits for one more pass, so it returns with its change applied.
    public func evaluateKeepAwake() async {
        if keepAwakeEvaluating {
            keepAwakeAgain = true
            await withCheckedContinuation { keepAwakeWaiters.append($0) }
            return
        }
        keepAwakeEvaluating = true
        repeat {
            keepAwakeAgain = false
            await evaluateKeepAwakeOnce(at: keepAwakeClock())
        } while keepAwakeAgain
        keepAwakeEvaluating = false
        let waiters = keepAwakeWaiters
        keepAwakeWaiters = []
        waiters.forEach { $0.resume() }
    }

    private func evaluateKeepAwakeOnce(at now: Date) async {
        guard !keepAwakeStopped else { return }
        guard keepAwakeEnabled || keepAwakeSwitch.owned else {
            // Off with nothing held: macOS sleep is neither read nor changed.
            keepAwakeWorkSeen = nil; setKeepAwakeActivity(false)
            setKeepAwakeStatus(KeepAwakeStatus(phase: .off, detail: Self.keepAwakeOff, enabled: false, ruleFile: powerControl.ruleFile()))
            return
        }
        // After a restart, sessions are unknown until the first discovery and screen read; a hold from the
        // earlier run is neither kept nor ended before then.
        if pollTask != nil && !initialDiscoveryComplete { return }
        // `sudo -n -l` runs only after turning it on or after a failed change, never on every pass.
        if keepAwakeRule == nil, now >= keepAwakeRetryAfter {
            let control = powerControl
            keepAwakeRule = await Task.detached(priority: .utility) { control.ruleInstalled() }.value
            guard !keepAwakeStopped else { return }
        }
        var reading = powerControl.read()
        let working = KeepAwake.working(snapshot.sessions, paused: snapshot.paused).count
        if snapshot.paused { keepAwakeWorkSeen = nil } else if working > 0 { keepAwakeWorkSeen = now }
        let blocked = keepAwakeBlock(reading, at: now)
        let releaseAt = keepAwakeWorkSeen.map { $0.addingTimeInterval(keepAwakeGrace) }
        let wanted = keepAwakeEnabled && keepAwakeRule == true && blocked == nil && releaseAt.map { now < $0 } == true
        let owned = keepAwakeSwitch.owned
        if owned && reading.sleepDisabled { keepAwakeSwitch.heartbeat() }
        if keepAwakeRule != nil, now >= keepAwakeRetryAfter {
            let floor = keepAwakeBatteryFloor
            if !reading.sleepDisabled {
                if wanted { _ = await changeKeepAwake(at: now) { try await $0.hold(floor: floor) } }
                else if owned { await keepAwakeSwitch.forget() }
            } else if owned {
                // A closed lid would have slept the Mac had AutoApprove not held it, so it sleeps now.
                let sleep = reading.lidClosed && reading.lidCausesSleep
                if wanted { _ = await changeKeepAwake(at: now) { try await $0.keepWatching(floor: floor) } }
                else if let failure = await changeKeepAwake(at: now, { try await $0.release(sleep: sleep) }) ?? nil {
                    keepAwakeFailure = "덮개가 닫혀 있지만 잠자기를 실행하지 못했습니다. \(failure)"
                }
            }
            reading = powerControl.read()
        }
        let holding = keepAwakeSwitch.owned && reading.sleepDisabled
        setKeepAwakeActivity(holding)
        setKeepAwakeStatus(keepAwakeStatus(reading, holding: holding, working: working, releaseAt: releaseAt, blocked: blocked))
    }

    private func changeKeepAwake<T: Sendable>(at now: Date, _ change: @escaping @Sendable (KeepAwakeSwitch) async throws -> T) async -> T? {
        do {
            let value = try await change(keepAwakeSwitch)
            keepAwakeFailure = nil
            return value
        } catch {
            keepAwakeFailure = error.localizedDescription
            keepAwakeRetryAfter = now.addingTimeInterval(keepAwakeRetryDelay)
            keepAwakeRule = nil
            return nil
        }
    }

    private func keepAwakeBlock(_ reading: PowerReading, at now: Date) -> KeepAwakeStatus.Phase? {
        if reading.onBattery, let percent = reading.batteryPercent, percent <= keepAwakeBatteryFloor { return .lowBattery }
        if reading.thermal == .serious || reading.thermal == .critical {
            keepAwakeCoolUntil = now.addingTimeInterval(keepAwakeCoolDown)
            return .hot
        }
        if let until = keepAwakeCoolUntil, now < until { return .hot }
        keepAwakeCoolUntil = nil
        return nil
    }

    private func keepAwakeStatus(_ reading: PowerReading, holding: Bool, working: Int, releaseAt: Date?, blocked: KeepAwakeStatus.Phase?) -> KeepAwakeStatus {
        let ruleFile = powerControl.ruleFile()
        func status(_ phase: KeepAwakeStatus.Phase, _ detail: String, releaseAt: Date? = nil) -> KeepAwakeStatus {
            KeepAwakeStatus(phase: phase, detail: detail, enabled: keepAwakeEnabled, ruleFile: ruleFile, working: working, releaseAt: releaseAt)
        }
        if !keepAwakeEnabled { return holding ? status(.holding, "끄는 중입니다. 잠자기 금지를 해제하고 있습니다.") : status(.off, Self.keepAwakeOff) }
        if let failure = keepAwakeFailure { return status(.failed, "잠자기 설정을 바꾸지 못했습니다. 잠시 후 다시 시도합니다. \(failure)") }
        if keepAwakeRule == nil { return status(.checking, Self.keepAwakeChecking) }
        if keepAwakeRule == false { return status(.setup, "관리자 권한 규칙이 없습니다. 끄고 다시 켜면 관리자 암호를 받아 설치합니다.") }
        if reading.sleepDisabled && !holding { return status(.external, "macOS 잠자기 금지가 이미 켜져 있습니다. 직접 켠 설정은 AutoApprove가 바꾸지 않습니다.") }
        if blocked == .lowBattery { return status(.lowBattery, "배터리가 \(keepAwakeBatteryFloor)% 이하라 평소처럼 잠듭니다. 전원을 연결하면 다시 켭니다.") }
        if blocked == .hot { return status(.hot, "Mac이 뜨거워 평소처럼 잠듭니다. 식은 뒤 5분이 지나면 다시 켭니다.") }
        if holding {
            return working > 0 ? status(.holding, "작업 중인 세션 \(working)개 · 덮개를 닫아도 잠들지 않습니다.")
                : status(.holding, "작업이 모두 끝났습니다. 잠시 뒤 평소처럼 잠듭니다.", releaseAt: releaseAt)
        }
        return status(.ready, "자동 승인을 켠 세션이 작업하는 동안 덮개를 닫아도 잠들지 않습니다.")
    }

    private func setKeepAwakeStatus(_ status: KeepAwakeStatus) {
        if snapshot.keepAwake != status { snapshot.keepAwake = status }
    }

    /// While it holds, App Nap must not slow the checks that answer approvals behind a closed lid.
    private func setKeepAwakeActivity(_ on: Bool) {
        if on, keepAwakeActivity == nil {
            keepAwakeActivity = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "덮개를 닫아도 자동 승인과 이어하기를 계속합니다.")
        } else if !on, let activity = keepAwakeActivity {
            ProcessInfo.processInfo.endActivity(activity); keepAwakeActivity = nil
        }
    }

    private func projectCapacityResumes() {
        let limit = capacityResumeDelays.count
        for id in Array(sessions.keys) {
            var presented: CapacityResume?
            if let state = capacityStates[id], sessions[id]?.phase != .ended {
                let phase: CapacityResume.Phase
                switch state.phase {
                case .waiting: phase = snapshot.paused ? .paused : .scheduled
                case .sending: phase = .sending
                case .sent: phase = .awaiting
                case .unavailable: phase = .unavailable
                case .review: phase = .review
                case .exhausted: phase = .exhausted
                case .cancelled: phase = .cancelled
                }
                presented = CapacityResume(phase: phase, attempt: state.attempt, limit: limit, deadline: phase == .scheduled ? state.deadline : nil)
            }
            if sessions[id]?.capacityResume != presented { sessions[id]?.capacityResume = presented }
        }
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
        guard !hasBackgroundChildren(id), claudeParents[id] == nil, !userInputHasPriority(id), !automaticInputBusy(id),
              let session = sessions[id], session.agent != .shell, session.automatic,
              session.channel.isScreen, !snapshot.paused,
              let state = screens[id], state.isCurrent, !state.attempted, state.scheduledID == nil,
              state.retryAfter.map({ Date() >= $0 }) ?? true else { return }
        let scheduledRevision = revision
        let scheduledID = UUID()
        screens[id]?.scheduledID = scheduledID
        let reader = processReader
        Task { [weak self] in
            let live = try? await Task.detached { try reader() }.value
            guard let self else { return }
            guard self.revision == scheduledRevision, !self.snapshot.paused, !self.userInputHasPriority(id), !self.automaticInputBusy(id), self.sessions[id]?.automatic == true,
                  self.sessions[id]?.channel == session.channel,
                  self.sessions[id]?.bridgeID == session.bridgeID,
                  self.sessions[id]?.terminalID == session.terminalID,
                  self.sessions[id]?.orcaHandle == session.orcaHandle,
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
            let host = ScreenHost(channel: session.channel)
            var event = AuditEvent(sessionID: id, summary: current.prompt.summary, outcome: "승인 시도 · 결과 미확인", source: "\(host?.title ?? "VS Code") 화면",
                context: AuditContext(session: session), request: session.agent == .codex ? current.prompt.dialog : current.prompt.summary)
            // Persist the attempt before dispatch; a crash or missing acknowledgement remains traceable.
            guard self.log(event) else {
                self.sessions[id]?.pendingInTerminal = true
                self.sessions[id]?.activityDetail = "승인 내역을 저장하지 못했습니다. 터미널에서 요청을 확인해주세요."
                self.screens[id]?.reviewDetail = self.sessions[id]?.activityDetail
                self.publish(); return
            }
            if let host, let adapter = self.screenAdapters[host] {
                self.automaticInputSessions.insert(id)
                defer { self.automaticInputSessions.remove(id) }
                // The agent's foreground job, for hosts that can name the process they would type into.
                let job = live?.first { $0.pid == session.pid && $0.started == session.started }.map { agent in
                    (live ?? []).filter { $0.tty == agent.tty && $0.processGroup == agent.processGroup }.map(\.pid)
                } ?? []
                let target = ScreenTarget(tty: session.tty, handle: session.screenHandle, jobPIDs: job,
                    sourcePID: session.pid, sourceStarted: session.started)
                let approve = adapter.approve, raw = current.raw, kind = session.agent
                do {
                    let delivery = try await Task.detached { try approve(target, raw, kind) }.value
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
