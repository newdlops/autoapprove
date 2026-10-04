import Foundation

public enum AgentKind: String, Codable, CaseIterable {
    case claude, codex, shell
    public var title: String {
        switch self { case .claude: return "Claude Code"; case .codex: return "Codex"; case .shell: return "일반 터미널" }
    }
}

public enum TerminalKind: String, Codable {
    case terminal, vscode, iterm, orca, pty, claudeBackground, unknown
    public var title: String {
        switch self {
        case .terminal: return "Terminal"
        case .vscode: return "VS Code"
        case .iterm: return "iTerm2"
        case .orca: return "Orca"
        case .pty: return "PTY"
        case .claudeBackground: return "Claude 백그라운드"
        case .unknown: return "터미널 미확인"
        }
    }
}

/// Terminal apps whose screens AutoApprove reads and answers without the agent's hooks.
public enum ScreenHost: String, CaseIterable, Codable, Sendable {
    case terminal, iterm, orca, pty
    public init?(kind: TerminalKind) {
        switch kind { case .terminal: self = .terminal; case .iterm: self = .iterm; case .orca: self = .orca; case .pty: self = .pty; default: return nil }
    }
    public init?(channel: ApprovalChannel) {
        switch channel { case .terminalScreen: self = .terminal; case .itermScreen: self = .iterm; case .orcaScreen: self = .orca; case .ptyScreen: self = .pty; default: return nil }
    }
    public var kind: TerminalKind {
        switch self { case .terminal: return .terminal; case .iterm: return .iterm; case .orca: return .orca; case .pty: return .pty }
    }
    public var channel: ApprovalChannel {
        switch self { case .terminal: return .terminalScreen; case .iterm: return .itermScreen; case .orca: return .orcaScreen; case .pty: return .ptyScreen }
    }
    public var title: String { kind.title }
    public var bundleID: String {
        switch self { case .terminal: return "com.apple.Terminal"; case .iterm: return "com.googlecode.iterm2"; case .orca: return "com.stablyai.orca"; case .pty: return "local.autoapprove.mac" }
    }
}

public enum SessionPhase: String, Codable {
    case unknown, working, approval, input, idle, ended
    public var title: String {
        switch self {
        case .unknown: return "상태 미확인"
        case .working: return "작업 중"
        case .approval: return "승인 대기"
        case .input: return "응답 필요"
        case .idle: return "대기 중"
        case .ended: return "종료"
        }
    }
}

public enum ApprovalChannel: String, Codable {
    case none, hook, terminalScreen, vscodeScreen, itermScreen, orcaScreen, ptyScreen
    public var title: String {
        switch self {
        case .none: return "연결 필요"
        case .hook: return "Claude 훅 연결됨"
        case .terminalScreen: return "Terminal 화면 연결됨"
        case .vscodeScreen: return "VS Code 화면 연결됨"
        case .itermScreen: return "iTerm2 화면 연결됨"
        case .orcaScreen: return "Orca 화면 연결됨"
        case .ptyScreen: return "PTY 연결됨"
        }
    }
    public var isScreen: Bool { self == .vscodeScreen || ScreenHost(channel: self) != nil }
}

public struct AgentSession: Identifiable, Codable, Equatable {
    public var id: String
    public var agent: AgentKind
    public var pid: Int32
    public var started: String
    public var tty: String
    public var cwd: String
    public var terminal: TerminalKind
    /// The owning app when it is known, including hosts AutoApprove cannot control.
    public var hostName: String?
    public var hostBundleID: String?
    /// Orca's pane handle from the agent's own launch environment.
    public var orcaHandle: String?
    public var terminalTitle: String?
    public var customization: SessionCustomization?
    public var notices: [SessionNotice]?
    /// A presentation-only group; hook routing always retains the original process session.
    public var backgroundSessions: [AgentSession]?
    public var ownPhase: SessionPhase?
    public var backgroundChildren: [AgentSession] { backgroundSessions ?? [] }
    public var unreadNoticeCount: Int { notices?.filter { !$0.isRead }.count ?? 0 }
    public var gitBranch: GitBranchState?
    public var phase: SessionPhase = .unknown
    public var channel: ApprovalChannel = .none
    public var automatic = false
    public var lastActivity = Date()
    public var idleSince: Date?
    /// Last observed background activity; optional for older bridge snapshots.
    public var backgroundMonitoring: Bool?
    public var activityDetail: String?
    public var providerID: String?
    public var terminalID: String?
    public var bridgeID: String?
    public var detail = "승인 연결을 확인하고 있습니다."
    public var pendingSummary: String?
    public var pendingRequestID: String?
    public var pendingInTerminal = false
    public var claudeApprovals: [ClaudeApproval]?
    public var queuedQuestions: [QueuedQuestion]?
    public var codexQuestionsObservedAt: Date?
    public var codexQuestionsError: String?
    public var completion: WorkCompletion?
    public var completionError: String?
    /// A Codex turn stopped at model capacity, while this session's auto-approval is on.
    public var capacityResume: CapacityResume?
    public var questions: [QueuedQuestion] { queuedQuestions ?? [] }
    public var unansweredQuestions: [QueuedQuestion] { questions.filter(\.needsAnswer) }
    public var isMonitoring: Bool { phase == .idle && backgroundMonitoring == true }
    public var phaseTitle: String { isMonitoring ? "대기 중 · 모니터링" : phase.title }
    public var needsReview: Bool { phase != .ended && (phase == .approval || phase == .input || questions.contains { $0.needsAnswer || $0.reply?.phase == .sending }) }
    public var canApprove: Bool { agent != .shell && phase != .ended && (channel != .none || backgroundChildren.contains(where: \.canApprove)) }
    public var automaticWaitingForConnection: Bool { automatic && !canApprove && phase != .ended }
    public var canReveal: Bool {
        phase != .ended && (terminal == .terminal || terminal == .iterm || (terminal == .orca && orcaHandle != nil)
            || (terminal == .vscode && bridgeID != nil && terminalID != nil))
    }
    public var hostTitle: String {
        switch terminal {
        case .unknown, .vscode: return hostName ?? terminal.title
        default: return terminal.title
        }
    }
    public var project: String { cwd.isEmpty ? "프로젝트 확인 중" : URL(fileURLWithPath: cwd).lastPathComponent }

    public init(id: String, agent: AgentKind, pid: Int32, started: String, tty: String, cwd: String, terminal: TerminalKind) {
        self.id = id; self.agent = agent; self.pid = pid; self.started = started
        self.tty = tty; self.cwd = cwd; self.terminal = terminal
    }

    public mutating func setPhase(_ phase: SessionPhase, detail: String, at date: Date = Date(), monitoring: Bool? = nil) {
        if self.phase != phase { lastActivity = date }
        idleSince = phase == .idle ? (self.phase == .idle ? idleSince ?? date : date) : nil
        if let monitoring { backgroundMonitoring = monitoring ? true : nil }
        if phase == .unknown || phase == .ended { backgroundMonitoring = nil }
        self.phase = phase; activityDetail = detail
        if phase == .ended { completion = nil; completionError = nil; gitBranch = nil }
    }
}

public struct CapacityResume: Codable, Equatable {
    public enum Phase: String, Codable { case scheduled, sending, awaiting, paused, unavailable, review, exhausted, cancelled }
    public var phase: Phase
    /// 1-based automatic attempt within the current run of failures.
    public var attempt: Int
    public var limit: Int
    public var deadline: Date?
    public var message: String
    public init(phase: Phase, attempt: Int, limit: Int, deadline: Date? = nil, message: String = CodexCapacityStop.resumeText) {
        self.phase = phase; self.attempt = attempt; self.limit = limit; self.deadline = deadline; self.message = message
    }
    public var canCancel: Bool { phase == .scheduled || phase == .paused }
}

public struct AuditContext: Codable, Equatable {
    public var agent: AgentKind
    public var cwd: String
    public var tty: String
    public var pid: Int32
    public var project: String { cwd.isEmpty ? "프로젝트 미확인" : URL(fileURLWithPath: cwd).lastPathComponent }
    public init(session: AgentSession) { agent = session.agent; cwd = session.cwd; tty = session.tty; pid = session.pid }
}

public enum AuditResult: String, CaseIterable, Codable {
    case delivered, review, manual, queued
    public var title: String {
        switch self { case .delivered: return "응답 전달"; case .review: return "확인 필요"; case .manual: return "터미널 응답"; case .queued: return "전달 대기" }
    }
}

public struct AuditEvent: Identifiable, Codable, Equatable {
    public var id: String = UUID().uuidString
    public var sessionID: String
    public var originSessionID: String?
    public var date = Date()
    public var summary: String
    public var outcome: String
    public var source: String
    public var context: AuditContext?
    public var tool: String?
    public var request: String?
    public var answer: String?
    public var result: AuditResult {
        if ["승인 전달", "승인 입력 전달", "질문 응답 전달", "이어서 진행 요청 전달", "웹 입력 전달"].contains(outcome) { return .delivered }
        if outcome == "터미널에서 확인" { return .manual }
        if outcome == "답변 대기열 등록" { return .queued }
        return .review
    }
    public var requestText: String { request ?? summary }
    public init(sessionID: String, summary: String, outcome: String, source: String, context: AuditContext? = nil, tool: String? = nil, request: String? = nil, answer: String? = nil) {
        self.sessionID = sessionID; self.summary = summary; self.outcome = outcome; self.source = source
        self.context = context; self.tool = tool; self.request = request; self.answer = answer
    }
}

public struct AuditPage {
    public var events: [AuditEvent]
    public var total: Int
}

public struct ConnectionHealth: Codable {
    public var terminal = "아직 연결하지 않음"
    public var terminalRequested = false
    public var terminalConnected = false
    public var terminalConnecting = false
    /// iTerm2 and Orca; absent from snapshots of older versions.
    public var screenHosts: [String: ScreenHostHealth]?
    public var vscode = "확장 연결 대기"
    public var claude = "훅 설치 필요"
    public var codex = "기존 CLI는 터미널 연결 사용"
    public var discoveryError: String?
    public var auditError: String?
    public var noticeError: String?
}

public struct ScreenHostHealth: Codable, Equatable {
    public var status = "아직 연결하지 않음"
    public var requested = false
    public var connected = false
    public var connecting = false
    public init() {}
}

extension ConnectionHealth {
    /// Terminal keeps its original flat fields for existing snapshot readers.
    public func screen(_ host: ScreenHost) -> ScreenHostHealth {
        guard host != .terminal else {
            var health = ScreenHostHealth()
            health.status = terminal; health.requested = terminalRequested
            health.connected = terminalConnected; health.connecting = terminalConnecting
            return health
        }
        return screenHosts?[host.rawValue] ?? ScreenHostHealth()
    }
    public mutating func setScreen(_ host: ScreenHost, _ health: ScreenHostHealth) {
        guard host != .terminal else {
            terminal = health.status; terminalRequested = health.requested
            terminalConnected = health.connected; terminalConnecting = health.connecting
            return
        }
        var hosts = screenHosts ?? [:]; hosts[host.rawValue] = health; screenHosts = hosts
    }
}

public struct EngineSnapshot: Codable {
    public static let questionNotificationDelayRange = 1...3600
    public var sessions: [AgentSession]
    public var events: [AuditEvent]
    public var paused: Bool
    public var health: ConnectionHealth
    /// Optional so snapshots from older versions retain the ten-second default.
    public var questionNotificationDelaySeconds: Int?
    /// Keeping the Mac awake with the lid closed; absent from snapshots of older versions.
    public var keepAwake: KeepAwakeStatus?
    public var questionNotificationDelay: Int {
        guard let value = questionNotificationDelaySeconds, Self.questionNotificationDelayRange.contains(value) else { return 10 }
        return value
    }
    public var idleCount: Int { sessions.filter { $0.phase == .idle }.count }
    public var monitoringCount: Int { sessions.filter(\.isMonitoring).count }
    public var attentionCount: Int { sessions.reduce(0) { $0 + AttentionRequest.candidates($1, paused: paused).count } }
}

public struct AppPaths {
    public let directory: URL
    public let socket: String
    public let database: String
    public init(directory: URL? = nil) {
        let environment = ProcessInfo.processInfo.environment
        self.directory = directory ?? environment["AUTOAPPROVE_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/AutoApprove")
        self.socket = self.directory.appendingPathComponent("bridge.sock").path
        self.database = self.directory.appendingPathComponent("state.sqlite").path
    }
    public func prepare() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
}

public enum AppError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case let .message(message) = self { return message }; return nil }
}
