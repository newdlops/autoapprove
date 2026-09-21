import Foundation

public enum AgentKind: String, Codable, CaseIterable {
    case claude, codex, shell
    public var title: String {
        switch self { case .claude: return "Claude Code"; case .codex: return "Codex"; case .shell: return "일반 터미널" }
    }
}

public enum TerminalKind: String, Codable {
    case terminal, vscode, unknown
    public var title: String {
        switch self { case .terminal: return "Terminal"; case .vscode: return "VS Code"; case .unknown: return "터미널 미확인" }
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
    case none, hook, terminalScreen, vscodeScreen
    public var title: String {
        switch self {
        case .none: return "연결 필요"
        case .hook: return "Claude 훅 연결됨"
        case .terminalScreen: return "Terminal 화면 연결됨"
        case .vscodeScreen: return "VS Code 화면 연결됨"
        }
    }
}

public struct AgentSession: Identifiable, Codable, Equatable {
    public var id: String
    public var agent: AgentKind
    public var pid: Int32
    public var started: String
    public var tty: String
    public var cwd: String
    public var terminal: TerminalKind
    public var terminalTitle: String?
    public var phase: SessionPhase = .unknown
    public var channel: ApprovalChannel = .none
    public var automatic = false
    public var lastActivity = Date()
    public var idleSince: Date?
    public var activityDetail: String?
    public var providerID: String?
    public var terminalID: String?
    public var bridgeID: String?
    public var detail = "승인 연결을 확인하고 있습니다."
    public var pendingSummary: String?
    public var pendingRequestID: String?
    public var pendingInTerminal = false
    public var queuedQuestions: [QueuedQuestion]?
    public var codexQuestionsObservedAt: Date?
    public var codexQuestionsError: String?
    public var questions: [QueuedQuestion] { queuedQuestions ?? [] }
    public var needsReview: Bool { phase != .ended && (phase == .approval || phase == .input || !questions.isEmpty) }
    public var canApprove: Bool { agent != .shell && channel != .none && phase != .ended }
    public var automaticWaitingForConnection: Bool { automatic && !canApprove && phase != .ended }
    public var canReveal: Bool {
        phase != .ended && (terminal == .terminal || (terminal == .vscode && bridgeID != nil && terminalID != nil))
    }
    public var project: String { cwd.isEmpty ? "프로젝트 확인 중" : URL(fileURLWithPath: cwd).lastPathComponent }

    public init(id: String, agent: AgentKind, pid: Int32, started: String, tty: String, cwd: String, terminal: TerminalKind) {
        self.id = id; self.agent = agent; self.pid = pid; self.started = started
        self.tty = tty; self.cwd = cwd; self.terminal = terminal
    }

    public mutating func setPhase(_ phase: SessionPhase, detail: String, at date: Date = Date()) {
        if self.phase != phase { lastActivity = date }
        idleSince = phase == .idle ? (self.phase == .idle ? idleSince ?? date : date) : nil
        self.phase = phase; activityDetail = detail
    }
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
    case delivered, review, manual
    public var title: String {
        switch self { case .delivered: return "응답 전달"; case .review: return "확인 필요"; case .manual: return "터미널 응답" }
    }
}

public struct AuditEvent: Identifiable, Codable, Equatable {
    public var id: String = UUID().uuidString
    public var sessionID: String
    public var date = Date()
    public var summary: String
    public var outcome: String
    public var source: String
    public var context: AuditContext?
    public var tool: String?
    public var request: String?
    public var answer: String?
    public var result: AuditResult {
        if ["승인 전달", "승인 입력 전달", "질문 응답 전달"].contains(outcome) { return .delivered }
        if outcome == "터미널에서 확인" { return .manual }
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
    public var vscode = "확장 연결 대기"
    public var claude = "훅 설치 필요"
    public var codex = "기존 CLI는 터미널 연결 사용"
    public var discoveryError: String?
    public var auditError: String?
}

public struct EngineSnapshot: Codable {
    public var sessions: [AgentSession]
    public var events: [AuditEvent]
    public var paused: Bool
    public var health: ConnectionHealth
    public var idleCount: Int { sessions.filter { $0.phase == .idle }.count }
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
