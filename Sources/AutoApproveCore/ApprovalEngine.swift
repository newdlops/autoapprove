import Foundation
import Combine
import CoreGraphics
import TerminalInputSupport

private struct ScreenAnalysisStorageKey: Hashable {
    let address: UInt
    let byteCount: Int
    let agent: String
}

@MainActor public final class ApprovalEngine: ObservableObject {
    @Published public private(set) var snapshot: EngineSnapshot {
        didSet { remoteDashboardRevision &+= 1; remoteInventoryChanges.notify() }
    }
    @Published public private(set) var initialDiscoveryComplete = false
    @Published public private(set) var webStatus = RemoteNetworkStatus()
    @Published public internal(set) var tunnelStatus = RemoteTunnelStatus()
    var tunnelController: RemoteTunnelController?
    var relayController:CloudflareRelayController?
    var tunnelRestoreAttempted = false
    var tunnelSetupID: UUID?
    var tunnelStartEpoch = UUID()
    var tunnelRefreshTask:Task<Bool,Error>?
    @Published public internal(set) var cloudflareStatus=CloudflareSetupStatus()
    var cloudflareClient:CloudflareOnboarding?
    let cloudflareServices:CloudflareServices
    let workersServices:CloudflareWorkersServices,relayServices:CloudflareRelayServices
    var workersClient:CloudflareWorkersOnboarding?
    var cloudflareSetupProvider:RemoteTunnelProvider = .managed
    @Published public internal(set) var tunnelPINConfigured=false
    var tunnelPINSetupID:UUID?
    @Published public private(set) var lanUpdate = LANUpdateStatus() {
        didSet { remoteDashboardRevision &+= 1; remoteInventoryChanges.notify() }
    }
    private(set) var remoteDashboardRevision: UInt64 = 0
    let remoteInventoryChanges = RemoteTerminalChangeSignal()
    public lazy var appUpdates = AppUpdates(engine: self, services: publishedUpdateServices)
    lazy var updateReceiver = LANUpdateReceiver(engine: self)
    func installationNodeID() throws -> String {
        if let id = store.value("webNodeID"), UUID(uuidString: id) != nil { return id }
        let id = UUID().uuidString; try store.set("webNodeID", id); return id
    }
    public var finishLANUpdate: @MainActor () -> Void = {}
    private var lanUpdateSleepTransferred = false

    func prepareLANUpdateExit() {
        keepAwakeSwitch.transferNow()
        lanUpdateSleepTransferred = true
    }
    public private(set) var webService: RemoteNetworkService?
    private let launchLoopbackOnly: Bool
    /// Shared-computer mode: the web server listens only on this Mac, and LAN
    /// discovery, peer links, LAN updates and external tunnels stay off.
    @Published public private(set) var networkIsolated = false
    private var webLoopbackOnly: Bool { launchLoopbackOnly || networkIsolated }
    private let nativeKeyboardActivity:NativeKeyboardActivity
    let publishedUpdateServices:PublishedUpdateServices
    public let managedPTY: ManagedPTYManager
    public let codexDiagnostics:CodexDiagnostics
    private let diagnosticEnvironment:@Sendable(ProcessRecord)->[String:String]?
    private var diagnosticRequestIntents:[String:String]=[:]
    private var diagnosticCollectingRequest:String?
    private var diagnosticPreparations:[String:CodexDiagnosticJob]=[:]
    private var diagnosticPreparationTask:Task<Void,Never>?
    private var latestDiagnosticRequestID:String?
    public var agentAccounts=AgentAccounts() {didSet {configureNativeCodexLogin()}}
    let accountPINReader=RemoteAccountPINReader()
    public let webQuestions = WebQuestionInbox()
    public let testScreens: TestScreenSharing
    public let backgroundDesktop = BackgroundDesktopController()
    /// On by default: Claude's focus-taking computer-use calls are redirected to the background desktop tools.
    public var backgroundComputerUseGuard: Bool { store.value("backgroundComputerUseGuard") != "false" }
    public func setBackgroundComputerUseGuard(_ enabled: Bool) throws { try store.set("backgroundComputerUseGuard", enabled ? "true" : "false") }
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
    private struct RemoteObservedScreen: Sendable { var raw: String; var generation: String; var observedAt: Date; var appearance: TerminalAppearance? = nil; var cursor: TerminalCursor? = nil; var orcaBinding: RemoteOrcaBinding? = nil; var display: TerminalTextSnapshot? = nil }
    private final class RemoteScreenRead {
        let token: UUID
        let target: ScreenTarget
        let generation: String
        let task: Task<RemoteObservedScreen, Error>
        var observedAt: Date?
        var sourceRevision: UInt64?
        var activeReaders = 0
        init(token: UUID, target: ScreenTarget, generation: String, task: Task<RemoteObservedScreen, Error>) {
            self.token = token; self.target = target; self.generation = generation; self.task = task
        }
    }
    private static let remoteReadCacheLifetime: TimeInterval = 0.6
    private var remoteScreenReads: [String: RemoteScreenRead] = [:]
    private struct RemoteInitialRead { var read: RemoteScreenRead; var waiters: Set<UUID> }
    private var remoteInitialReads: [String: RemoteInitialRead] = [:]
    private var remoteMonitorFrames: [String: RemoteObservedScreen] = [:]
    private var remoteObservedScreens: [String: RemoteObservedScreen] = [:]
    private var remoteTerminalChanges: [String: RemoteTerminalChangeSignal] = [:]
    private var remoteFrames: [String: (frame: RemoteTerminalFrame, raw: String, generation: String, usesRawPresentation: Bool, orcaBinding: RemoteOrcaBinding?, nativeBinding: NativeBridgeBinding?, agent: AgentKind)] = [:]
    private var nextRemoteFramePruneAt: TimeInterval = 0
    private let orcaSnapshotReader: (@Sendable (String) async throws -> OrcaTerminalSnapshot)?
    private var remoteOrcaBindings: [String: (targetGeneration: String, binding: RemoteOrcaBinding)] = [:]
    private var remoteInputSessions = Set<String>()
    private var remotePTYInput = Set<String>()
    private var ptySessionBindings: [String: String] = [:]
    private var ptyContinuations: [String: (source: String, conversation: String?, ptyID: String)] = [:]
    private var ptyContinuationTasks: [String: Task<ManagedPTYDescriptor, Error>] = [:]
    private var automaticInputSessions = Set<String>()
    // API responses and terminal navigation share the same session reservation.
    // An old completion must never release a newer request's reservation.
    private var codexServerInputReservations: [String: String] = [:]
    private let automationRuntime = AutomationRuntime()
    private var automationNeedsFreshScreen = Set<String>()
    private struct ResetApprovalReceipt {
        let dispatchID: UUID
        let generation: String
        let requestIdentity: String
    }
    private var resetApprovalReceipts: [String: ResetApprovalReceipt] = [:]
    private var systemSafetyStates: [String: SystemSafetyState] = [:]
    private var systemSafetyTasks: [String: UUID] = [:]
    private let osPermissionServices:OSPermissionServices
    private let osPermissionMonitoringEnabled:Bool
    private var osPermissionTask:Task<Void,Never>?
    private var osPermissionScanning=false
    private var osPermissionRequests:[String:OSPermissionRequest]=[:]
    private var osPermissionClaims:[String:(sessionID:String,token:String,source:String)]=[:]
    private var osPermissionPolicySources:[String:String]=[:]
    private var osPermissionReceipts:Set<String>=[]
    private var osPermissionSeen:[String:Date]=[:]
    private var osPermissionBlocked=Set<String>()
    private var osPermissionActing:String?
    private var osPermissionEpoch=UUID()
    private struct OSPermissionTransition {var target:OSPermissionTarget;var kind:OSPermissionKind;var sessionID:String;var source:String;var until:Date}
    private var osPermissionTransitions:[String:OSPermissionTransition]=[:]
    private var remoteInputUntil: [String: Date] = [:]
    private var remoteStreams: [String: (generation: String, token: String, identity: TTYInputIdentity?)] = [:]
    private var remoteFrameSequence = 0
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
    let store: AuditStore
    private let claudeRegistryReader: @Sendable ([ProcessRecord]) -> [ClaudeSessionRegistration]
    private let processReader: @Sendable () throws -> [ProcessRecord]
    // Explicit internal seam for owned native CLI fixtures. Production always
    // resolves the original OpenAI executable and the connected daemon.
    var codexAttachmentRuntime: @Sendable (CodexSessionLaunch,String,CodexSessionAttachment.ExecutionMode) async throws ->CodexCLIContext = {
        try await $0.reconnectionContext(home:$1,mode:$2)
    }
    private let codexGroupReader: @Sendable (ProcessRecord) throws -> CodexThreadLocation?
    private let codexGroupEnvironment: @Sendable (ProcessRecord) -> [String: String]?
    private let groupModelSettingsReader: @Sendable (SessionGroupLiveSession) -> SessionGroupModelSettings?
    private let profileExecutionSettingsReader: @Sendable (SessionGroupLiveSession) -> TerminalProfileExecutionSettings?
    private let groupTranscriptReader: SessionGroupModelSettingsReader
    private var groupRecoveryAt = Date.distantPast
    private let groupClaudeCompletionReader: @Sendable (SessionGroupLiveSession, Date, String) -> WorkCompletion?
    private let singleProcessReader: @Sendable (Int32) throws -> [ProcessRecord]
    private let discoveryReader: @Sendable () throws -> [ProcessRecord]
    private var workingDirectoriesBySession: [String: String] = [:]
    private var workingDirectoryReadAt: [String: TimeInterval] = [:]
    private let remoteProcessVerifier: @Sendable (AgentSession) throws -> Bool
    private var claudeParents: [String: String] = [:]
    private var recoveredClaudeStates = Set<String>()
    private var claudeHookObservedAt: [String: Date] = [:]
    /// Status Claude registered for each interactive process ("idle", "busy", "waiting", "shell").
    private var claudeRegistryStatus: [String: String] = [:]
    private struct LiveClaudeHook {
        var request: ClaudeHookRequest
        var receipt: ClaudeHookReceipt
        var lastContact: Date
        var questionEditing = false
    }
    private var liveClaudeHooks: [String: LiveClaudeHook] = [:]
    private var projectedClaudeApprovalSessionIDs = Set<String>()
    private var claudeHookSignals: [String: RemoteTerminalChangeSignal] = [:]
    private var claudeHookWaitTasks: [String: (token: UUID, task: Task<Void, Never>)] = [:]
    private var parentSaveFailed = false
    private let codexQuestions = CodexQuestionCollector()
    private var codexCompletions = CodexCompletionTracker()
    private var codexTurns: [String: (state: CodexTurnState, observedAt: Date)] = [:]
    private var retainedDiscoverySessionIDs: Set<String>?
    private var retainedTmuxHandles: Set<String>?
    private var claudeWorkIDs: [String: String] = [:]
    private let questionTransport: CodexReplyTransport
    private let codexQueue: CodexQueueTransport
    private var codexApprovalTasks:[String:Task<Void,Never>]=[:]
    private var codexApprovalEpochs:[String:UUID]=[:]
    private let codexConversation:CodexConversationTransport
    private let codexGoals:CodexGoalTransport
    private let codexSubagentGoals:CodexSubagentGoalServices
    private var changingGoals=Set<String>()
    private var changingGoalThreads=Set<String>()
    private var cohortRestartCoordinator:CodexCohortRestart?
    private var cohortExecutionTasks:[UUID:Task<CodexCohortRestartState,Error>]=[:]
    private var cohortHeldSessionIDs=Set<String>()
    private var nextCohortRecovery=Date.distantPast
    private var cohortRecoveryScheduled=Set<UUID>()
    private var officialAttachmentHomes=Set<String>()
    private var officialAttachmentRetryAfter:[String:Date]=[:]
    private var goalRecoveryTask:Task<Void,Never>?
    private var nextGoalRecovery=Date.distantPast
    private var recoveringGoalIntents=false
    private var manualGoalHoldCache:[String:String]=[:]
    private var clearingCodexQueues = Set<String>()
    private var replyingQuestions = Set<String>()
    private var sendingMessages = Set<String>()
    /// Session group task history, read from the store on first use.
    private var groupOrchestrationCache: SessionGroupOrchestration?
    private var groupWorkerActions = Set<String>()
    private var groupDeliveryTask: Task<Void, Never>?
    private var groupMailboxStore: SessionGroupMailbox?
    private var groupWaitTimer: Task<Void, Never>?
    private let groupMailboxSignal = RemoteTerminalChangeSignal()
    private var groupMailboxIdleSessions: Set<String> = []
    private var groupMailboxTask: Task<Void, Never>?
    private var activeGroupMailboxMessages: Set<UUID> = []
    private var claudeGroupPrompts: [String: (prompt: String, turn: String)] = [:]
    private var groupMailboxDelegations: [String: (id: UUID, at: Date, group: String)] = [:]
    public var groupMailboxPollInterval: TimeInterval = 5
    public static let groupMessageTTLMinutesRange = 1...10_080
    public var groupMessageTTLMinutes: Int {
        guard let raw = store.value("groupMessageTTLMinutes"), let minutes = Int(raw),
              Self.groupMessageTTLMinutesRange.contains(minutes) else { return 120 }
        return minutes
    }
    public func setGroupMessageTTLMinutes(_ minutes: Int) throws {
        guard Self.groupMessageTTLMinutesRange.contains(minutes) else {
            throw AppError.message("그룹 메시지 만료 시간은 1~10,080분으로 지정해주세요.")
        }
        try store.set("groupMessageTTLMinutes", String(minutes))
        scheduleGroupMailboxDelivery()
    }
    public var groupMailboxReminderInterval: TimeInterval = 120
    /// Retry timer for a message held because its recipient is busy; the idle signal normally comes first.
    public var groupMailboxHeldFallback: TimeInterval = 300
    /// How often the loop parks messages for removed members and tells senders about stalled messages.
    public var groupMailboxHousekeepingInterval: TimeInterval = 60
    private var groupHousekeepingAt = Date.distantPast
    /// How long a typed group message may go unobserved before the engine looks for proof of loss.
    public var groupMailboxReceiptGrace: TimeInterval = 60
    /// Typings without an observed receipt before a message is parked as undelivered.
    public var groupMailboxDirectAttemptLimit = 3
    /// How long an agent's message may wait without being typed before its sender is told once.
    public var groupStallNoticeAfter: TimeInterval = 600
    private var sessionRestartTasks: [String: Task<Void, Never>] = [:]
    /// Conversation IDs read the way session groups read them, once per restart request.
    private var restartIdentityTask: Task<[String: String], Never>?
    /// Exiting a CLI, opening a tab and typing the resume command happen for one session at a time:
    /// Terminal opens one tab at a time, and parallel typing missed its input deadlines.
    private var restartTerminalBusy = false
    private var restartResumesWork = true
    /// How long a restarted CLI may take to accept input, and how long it must stay idle before the resume line is typed.
    public var restartResumeWait: TimeInterval = 90, restartResumeSettle: TimeInterval = 2
    /// Reads a CLI's original arguments for a restart. Tests replace it; it never runs for other processes.
    public var processArgumentsReader: @Sendable (ProcessRecord) -> [String]? = { ProcessEnvironment.arguments($0) }
    public var processPathReader: @Sendable (ProcessRecord) -> String? = { ProcessEnvironment.executablePath($0) }
    /// Ends a CLI for a restart. A signal needs no terminal input, which a changing screen can reject.
    public var processTerminator: @Sendable (ProcessRecord) -> Bool = { kill($0.pid, SIGTERM) == 0 }
    private var sessionGroupBadges: [String: SessionGroupBadge] = [:]
    private var groupBadgeTask: Task<Void, Never>?
    private var groupBadgeRefreshPending = false
    private var groupBadgeSessionIDs: Set<String> = []
    private var groupBadgeRefreshedAt = Date.distantPast
    private var groupConnectionObservation: (at: Date, sessions: [SessionGroupLiveSession])?
    /// Sessions whose next choice input is a parent's delegated permission answer.
    private var delegatedPermissionInputs: Set<String> = []
    private var groupQuestionSeen: [UUID: (id: String, since: Date)] = [:]
    /// How long a worker must stay on the same choice question before its parent is asked.
    public var groupQuestionGrace: TimeInterval = 8
    /// How often group reports, questions and approval requests are checked. Tests shorten it.
    public var groupDeliveryInterval: TimeInterval = 2
    private var readableQuestionSessions = Set<String>()
    private var questionThreadBySession: [String: String] = [:]
    private var restoredQuestionIDs = Set<String>()
    private var questionAutomationOverrides: [String: QuestionAutomation.Phase] = [:]
    private struct QuestionConfirmationKey: Hashable {
        let sessionID: String
        let title: String
        let options: [String]
        let multiSelect: Bool
        init(sessionID: String, question: QueuedQuestion) {
            self.sessionID = sessionID; title = question.title; options = question.options; multiSelect = question.multiSelect ?? false
        }
    }
    private struct QuestionConfirmationCache {
        private var detected: [QuestionConfirmationKey: AutomaticQuestionDecision] = [:]
        private var checked = Set<QuestionConfirmationKey>()
#if DEBUG
        private(set) var detectionCount = 0
#endif
        mutating func confirmation(sessionID: String, question: QueuedQuestion) -> AutomaticQuestionDecision? {
            let key = QuestionConfirmationKey(sessionID: sessionID, question: question)
            if checked.contains(key) { return detected[key] }
            checked.insert(key)
#if DEBUG
            detectionCount += 1
#endif
            let result = AutomaticQuestionDecision.detect(question)
            if let result { detected[key] = result }
            return result
        }
    }
#if DEBUG
    public private(set) var debugQuestionConfirmationDetections = 0
#endif
    private struct PersistedQuestionSettings {
        var dismissalLoaded = false
        var dismissed = false
        var automationLoaded = false
        var automation: QuestionAutomation.Phase?
    }
    private var persistedQuestionSettings: [String: PersistedQuestionSettings] = [:]
    private static let persistedQuestionSettingsLimit = 2_048
    private var cachedDuplicateQuestionIDsBySession: [String: Set<String>] = [:]
    private var duplicateQuestionIDsDirty = true
    private var automaticQuestionReplies: [String: AutomaticQuestionReply] = [:]
    private struct ModelRetentionTask {
        let token: UUID
        let questionID: String
        let generation: String
        let revision: UInt64
        let task: Task<Void, Never>
    }
    private var modelRetentionTasks: [String: ModelRetentionTask] = [:]
    private var manuallyChangedModelQuestions: [String: String] = [:]
    private var retainedModelMenus: [String: String] = [:]
    private var questionAutomationStopped = false
    private struct AutomaticQuestionReply {
        var token: UUID
        var sessionID: String
        var question: QueuedQuestion
        var answer: String
        var sending = false
        var deadline: Date
        var task: Task<Void, Never>
    }
    private var sessions: [String: AgentSession] = [:]
    private var sessionOrder: [String] = []
    private var inboxes: [String: SessionInbox] = [:]
    private var noticeKeyCache: SessionNotice.KeyCache?
    private var records: [ProcessRecord] = []
    private var server: SocketServer?
    private var pollTask: Task<Void, Never>?
    private var historyPollTask: Task<Void, Never>?
    private var screenPollTasks: [ScreenHost: Task<Void, Never>] = [:]
    private var unchangedScreenReads: [ScreenHost: Int] = [:]
    // Each session keeps its own monitor cadence. One question screen must not
    // make every other tab of the same host read at the question cadence:
    // every Terminal read is an Apple Event that Terminal checks with tccd.
    private var screenReadAt: [String: TimeInterval] = [:]
    private var unchangedSessionReads: [String: Int] = [:]
    private var screenReadSucceeded: Set<String> = []
    private var observationEpoch: UInt64 = 0
    private let historyPollSignal = RemoteTerminalChangeSignal()
    private let screenPollSignals = Dictionary(uniqueKeysWithValues: ScreenHost.allCases.map { ($0, RemoteTerminalChangeSignal()) })
    private var gitBranchTask: Task<Void, Never>?
    private var gitBranchTargets: [String: String] = [:]
    private var gitBranchRefreshUptime: TimeInterval = 0
    private var peers: [String: SocketConnection] = [:]
    private var bridges: [String: [JSONObject]] = [:]
    private var screens: [String: ScreenState] = [:]
    private var activityTrackers: [String: ActivityTracker] = [:]
    private var codexProgressTrackers:[String:CodexProgressTracker]=[:]
    private var codexProgressHistory:[String:(token:String,at:Date)]=[:]
    private var codexProgressJobs:[String:UUID]=[:]
    public var codexProgressTimeout:TimeInterval=CodexProgressRecovery.timeout
    public var codexProgressWaitSeconds:TimeInterval=20
    /// Only immutable parsing results are reused. Policies, reservations and delivery checks stay live.
    private var screenAnalyses: [String: ScreenAnalysis] = [:]
    private var screenAnalysisCacheBytes = 0
    private let screenAnalysisCacheScreenLimit = 512 * 1_024
    private let screenAnalysisCacheTotalLimit = 8 * 1_024 * 1_024
    private var screenPublicationDepth = 0
    private var screenPublicationPending = false
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
    private var terminalHistoryStore:TerminalHistoryStore?
    private let terminalProfileLayoutReader:@Sendable ([String]) throws -> [TerminalProfileTabSnapshot]
    /// A brief cancellation window for supported yes/no confirmations. Ordinary
    /// permission screens are handled immediately; unsafe system changes deny.
    public var automaticConfirmationDelay: TimeInterval = 0.5
    private var confirmationDelay: TimeInterval {
        automaticConfirmationDelay.isFinite ? min(30, max(0, automaticConfirmationDelay)) : 0.5
    }
    /// Seconds before each automatic continue; repeated capacity failures reuse the final delay.
    public var capacityResumeDelays: [TimeInterval] = [30, 60, 120, 240, 480]
    /// Transient connection failures continue with a bounded delay until progress or cancellation.
    public var interruptionResumeDelays: [TimeInterval] = [1, 15, 30, 60, 120, 300]
    /// Authentication/configuration fixes may happen outside the CLI. Keep checking slowly.
    public var accountErrorResumeDelays: [TimeInterval] = [60, 120, 300, 600]
    /// A blocked Goal rechecks external conditions at a slower cadence than a network error.
    public var goalBlockedResumeDelays: [TimeInterval] = [30, 60, 120, 300]
    /// Wait after a final check that typed nothing, before trying the next fresh frame.
    public var capacityUnsentRetryDelay: TimeInterval = 3
    /// A continued turn that keeps working this long made progress: its next stop starts a new run.
    public var capacityProgressWindow: TimeInterval = 120
    private struct CapacityState {
        enum Phase { case waiting, sending, sent, unavailable, review, cancelled }
        var phase: Phase
        var stop: CodexCapacityStop
        var channel: ApprovalChannel
        var attempt: Int
        var deadline: Date
        var observedAt: Date
        var scheduledID: UUID?
        var dispatchID: UUID?
        var sentAt: Date?
        var unsent = 0
        var workingObserved = false
        var turnIdentity: String?
        var submitOnly = false
    }
    private var capacityStates: [String: CapacityState] = [:]
    private var projectedCapacityResumeIDs = Set<String>()
    private var legacyResumeDraftReceipts: [String: [CodexCapacityStop]] = [:]
    private var exitRecoveries: [String: SessionExitRecovery] = [:]
    // Capture once per original process, off the main actor. Completed tasks also
    // cache failed reads, so ordinary screen polling cannot repeatedly probe it.
    private var exitLaunchReads: [String: Task<CodexSessionLaunch?,Never>] = [:]
#if DEBUG
    func observedExitLaunch(_ id:String) async ->CodexSessionLaunch? {await exitLaunchReads[id]?.value}
#endif
    private var exitRecoveryTasks: [String: UUID] = [:]
    private var conversationReads = Set<String>()
    /// Retained for source compatibility. Enabled keep-awake now lasts for the app lifetime.
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
    private var keepAwakeRetryAfter = Date.distantPast
    private var keepAwakeFailure: String?
    private var keepAwakeEvaluating = false
    private var keepAwakeAgain = false
    private var keepAwakeWaiters: [CheckedContinuation<Void, Never>] = []
    /// Set by `stop()`: a check that resumes afterwards changes nothing.
    private var keepAwakeStopped = false
    private var keepAwakeTask: Task<Void, Never>?
    private let keepAwakeSignal = RemoteTerminalChangeSignal()
    private var keepAwakeActivity: NSObjectProtocol?
    private let mouseActivity: MouseActivity
    private var mouseActivityTask: Task<Void, Never>?
    private var discovering = false
    @Published public private(set) var codexAccountTransitionEnabled = false
    @Published public private(set) var codexAccountTransitionStates: [String: CodexAccountTransitionState] = [:]
    @Published public private(set) var codexAccountTransitionBusy = false
    @Published public private(set) var codexAccountTransitionNotice: String?
    public var codexAccountTransitionHeld: Bool { codexAccountTransitionStates.values.contains(where: \.held) }
    private let codexAccountTransitionServices: CodexAccountTransitionServices
    private let codexManagedServerServices:CodexManagedServerServices
    private let codexAccountInspectionServices:CodexAccountInspectionServices
    private var codexAccountInspectionTasks:[String:(id:UUID,task:Task<CodexAccountInspection,Error>)]=[:]
    private var codexAccountInspectionEpochs:[String:UUID]=[:]
    @Published public private(set) var codexSessionAttachmentNotice:String?
    private var codexSessionAttachments:[String:CodexSessionAttachment]=[:]
    private var codexAttachmentWaitReasons:[String:String]=[:]
    private var codexAttachmentToolHostGrants:[String:[String:[ProcessRecord]]]=[:]
    private var codexAttachmentHomes:Set<String>=[]
    private var codexNativeAttachmentTask:Task<Void,Never>?
    private var codexNativeAttachmentPending:Set<String>=[]
    private var codexNativeAttachmentFailures:Set<String>=[]
    private var codexAttachmentActiveIDs:Set<String>=[]
    private var codexManagedServerAutomaticTask:Task<Void,Never>?
    private var codexManagedServerAutomaticHomes:Set<String>=[]
    private var codexManagedServerStartTask:Task<CodexManagedServerStatus,Error>?
    private let codexAccountTargetReader: @Sendable ([ProcessRecord]) async throws -> [CodexAccountTransitionTarget]
    private var codexAccountCoordinators: [String: CodexAccountTransitionCoordinator] = [:]
    private var codexMigrationCoordinator:CodexSessionMigrationCoordinator?
    private var codexMigrationHeldClients:Set<CodexMigrationClientID>=[]
    private var codexMigrationRecoveryError:String?
    private var codexMigrationReconnectContexts:[String:SessionExitRecovery]=[:]
    private var codexMigrationReconnectRecoveryError:String?
    private var codexMigrationRunningIDs:Set<String>=[]
    private var codexAccountObservedTargets: [CodexAccountTransitionTarget] = []
    private var codexAccountMembershipVerifiedAt:Date?
    private var codexAccountMembershipRefreshTask:Task<Void,Never>?
    private var codexAccountTransitionTask: Task<Void, Never>?
    private var codexAccountCheckTask:Task<Void,Never>?
    private var codexAccountNativeWakePending=false
    private let codexAccountTransitionSignal=RemoteTerminalChangeSignal()
    private var codexAccountTransitionEpoch = UUID()
    private static let codexAccountJournalKey = "codexAccountTransitions.v1"
    private static let codexAccountLoginRequestsKey = "codexAccountLoginRequests.v1"
    private var codexAccountLoginRequests: [String:String] = [:]
    private var recordedNativeCodexLoginIDs:Set<String>=[]
    private func codexAccountInputHeld(_ id: String) -> Bool {
        if cohortHeldSessionIDs.contains(id){return true}
        guard let session=sessions[id],session.agent == .codex else{return false}
        return codexMigrationRecoveryError != nil || codexMigrationReconnectRecoveryError != nil
            || codexMigrationReconnectContexts.values.contains(where:{$0.session.tty==session.tty})
            || codexMigrationHeldClients.contains(.init(pid:session.pid,started:session.started,tty:session.tty))
            || codexAccountTransitionInputHeld(session) || codexAttachmentActiveIDs.contains(id) || codexSessionAttachments.values.contains {
            [.needsPause,.pauseReserved,.waitingPause,.needsTab,.tabReserved,.exitReserved,.waitingShell,.launchReserved,.verifying].contains($0.phase) && ($0.context.session.tty==session.tty || ($0.replacesTab && "/dev/"+$0.context.shell.tty==session.tty))
        }
    }
    /// The native session view uses the same barrier as the input transports,
    /// including clients whose server membership is not yet verified.
    public func codexApprovalHoldReason(sessionID:String)->String? {
        guard let session=sessions[sessionID],session.phase != .ended,codexAccountInputHeld(sessionID) else{return nil}
        if let error=codexMigrationRecoveryError ?? codexMigrationReconnectRecoveryError {
            return "로그인 그룹 이동 기록을 확인하지 못해 자동 입력을 보류합니다. "+error
        }
        if codexMigrationHeldClients.contains(.init(pid:session.pid,started:session.started,tty:session.tty)) {
            return "로그인 그룹 이동 준비·실행 중입니다. 이동을 완료하거나 실행 전 준비를 취소하면 자동 승인을 다시 확인합니다."
        }
        return "계정 전환·세션 연결을 확인하는 동안 자동 승인을 보류합니다. 계정·로그인에서 진행 상태를 확인하거나 남은 전환을 중지해주세요."
    }
    private func codexAccountTransitionInputHeld(_ session:AgentSession,home:String?=nil)->Bool {
        let held=codexAccountTransitionStates.filter {key,state in state.held && (home==nil || home==key)}
        guard !held.isEmpty else{return false}
        func matches(_ witness:CodexAccountTransitionWitness)->Bool {
            witness.pid==session.pid && witness.started==session.started && witness.tty==session.tty
        }
        // Retain the original barrier even while its socket disappears during
        // restart. PID alone cannot authorize a reused process or terminal.
        if held.values.contains(where:{$0.witnesses.contains(where:matches)}) {return true}
        guard codexAccountMembershipFresh else{return true}
        let homes=Set(codexAccountObservedTargets.filter{$0.witnesses.contains(where:matches)}.map(\.home))
        // Release unrelated inputs only with positive, unambiguous evidence of
        // a different server. Unknown clients retain the conservative barrier.
        guard homes.count==1,let connected=homes.first else{return true}
        return held[connected] != nil
    }
    private var codexAccountMembershipFresh:Bool {
        guard let checked=codexAccountMembershipVerifiedAt else{return false}
        let age=Date().timeIntervalSince(checked)
        return age>=0 && age<8
    }
    private func updateCodexAccountMembership(_ targets:[CodexAccountTransitionTarget]) throws {
        guard Set(targets.map(\.home)).count==targets.count else {throw AppError.message("같은 Codex 홈의 연결이 중복되어 전환을 보류했습니다.")}
        codexAccountObservedTargets=targets;codexAccountMembershipVerifiedAt=Date()
        if codexAccountTransitionHeld {startCodexAccountMembershipRefresh()}
    }
    private func startCodexAccountMembershipRefresh() {
        guard codexAccountMembershipRefreshTask==nil,!remoteInputStopped else{return}
        let epoch=codexAccountTransitionEpoch
        codexAccountMembershipRefreshTask=Task { [weak self] in
            // A daemon restart can await its graceful drain for several minutes.
            // Membership has its own read-only loop, independent of that wait.
            while !Task.isCancelled {
                do {try await Task.sleep(for:.seconds(2))} catch {break}
                guard let self,epoch==self.codexAccountTransitionEpoch,!self.remoteInputStopped,self.codexAccountTransitionHeld else{break}
                do {
                    let reader=self.processReader
                    let records=try await Task.detached(priority:.utility){try reader()}.value
                    let targets=try await self.codexAccountTargetReader(records)
                    guard !Task.isCancelled,epoch==self.codexAccountTransitionEpoch else{break}
                    let changed=targets != self.codexAccountObservedTargets || !self.codexAccountMembershipFresh
                    try self.updateCodexAccountMembership(targets)
                    if changed {self.publish()}
                } catch {
                    guard !Task.isCancelled,epoch==self.codexAccountTransitionEpoch else{break}
                    self.codexAccountObservedTargets=[];self.codexAccountMembershipVerifiedAt=nil
                    self.publish()
                }
            }
            if let self,epoch==self.codexAccountTransitionEpoch {self.codexAccountMembershipRefreshTask=nil}
        }
    }
    private static let codexAccountHoldMessage = "계정 전환을 위해 Codex 작업을 중단·대기하고 있습니다. 전환 결과를 확인한 뒤 입력해주세요."
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

    public init(paths: AppPaths = AppPaths(), terminalReader: (@Sendable ([String]) throws -> TerminalSnapshot)? = nil, questionTransport: CodexReplyTransport = .live, claudeRegistryReader: @escaping @Sendable ([ProcessRecord]) -> [ClaudeSessionRegistration] = { ClaudeSessionRegistry.read(records: $0) }, processReader: (@Sendable () throws -> [ProcessRecord])? = nil, screenAdapters: [ScreenHost: ScreenHostAdapter] = [:], powerControl: PowerControl = .live, managedPTY: ManagedPTYManager = ManagedPTYManager(), terminalWindowCapture: TerminalWindowCapture? = nil, itermWindowCapture: TerminalWindowCapture? = nil, orcaSnapshotReader: (@Sendable (String) async throws -> OrcaTerminalSnapshot)? = nil, requestTerminalKeyboardPermission: (@MainActor @Sendable () -> Void)? = nil, bridgeOwnerBundle: (@MainActor @Sendable (Int32) -> String?)? = nil, terminalInputAvailable: (@Sendable () -> Bool)? = nil,
                terminalInputIdentity: (@Sendable (Int32) -> TTYInputIdentity?)? = nil, testScreenSharing: TestScreenSharing? = nil,
                codexQueue: CodexQueueTransport = .live, mouseActivityControl: MouseActivityControl = .live,
                codexGroupReader: (@Sendable (ProcessRecord) throws -> CodexThreadLocation?)? = nil,
                codexGroupEnvironment: (@Sendable (ProcessRecord) -> [String: String]?)? = nil,
                groupModelSettingsReader: (@Sendable (SessionGroupLiveSession) -> SessionGroupModelSettings?)? = nil,
                profileExecutionSettingsReader: (@Sendable (SessionGroupLiveSession) -> TerminalProfileExecutionSettings?)? = nil,
                groupClaudeCompletionReader: (@Sendable (SessionGroupLiveSession, Date, String) -> WorkCompletion?)? = nil,
                webLoopbackOnly: Bool = false, isolateByDefault: Bool = false, singleProcessReader: (@Sendable (Int32) throws -> [ProcessRecord])? = nil,cloudflareServices:CloudflareServices = .live,
                workersServices:CloudflareWorkersServices = .live,relayServices:CloudflareRelayServices = .live,nativeKeyboardActivity:NativeKeyboardActivity? = nil,publishedUpdateServices:PublishedUpdateServices = .live,
                terminalProfileLayoutReader:(@Sendable ([String]) throws -> [TerminalProfileTabSnapshot])? = nil,
                osPermissionServices:OSPermissionServices? = nil,codexGoals:CodexGoalTransport = .live,codexConversation:CodexConversationTransport = .live,
                codexSubagentGoals:CodexSubagentGoalServices = .live,
                codexAccountTransitions:CodexAccountTransitionServices? = nil,
                codexAccountTargets:(@Sendable ([ProcessRecord]) async throws -> [CodexAccountTransitionTarget])? = nil,
                codexManagedServers:CodexManagedServerServices = .live,diagnosticServices:CodexDiagnosticServices = .live,
                codexAccountInspections:CodexAccountInspectionServices?=nil) throws {
        self.codexDiagnostics=CodexDiagnostics(services:diagnosticServices)
        if processReader==nil {self.diagnosticEnvironment={ProcessEnvironment.read($0)}}
        else {self.diagnosticEnvironment={_ in nil}}
        self.codexManagedServerServices=codexManagedServers
        self.codexAccountInspectionServices=codexAccountInspections ?? (processReader==nil ? .live:.inactive)
        self.codexAccountTransitionServices = codexAccountTransitions ?? .live
        let accountTargetReader:@Sendable([ProcessRecord]) async throws -> [CodexAccountTransitionTarget]
        if let codexAccountTargets {accountTargetReader=codexAccountTargets}
        else if processReader==nil {accountTargetReader={try await CodexAccountTransitionTarget.discover($0)}}
        else {accountTargetReader={_ in []}}
        self.codexAccountTargetReader={records in
            var targets=try await accountTargetReader(records)
            for index in targets.indices {targets[index].home=try CodexAccountTransitionTarget.canonicalHome(targets[index].home)}
            return targets
        }
        self.codexConversation=codexConversation
        self.paths = paths
        self.osPermissionServices=osPermissionServices ?? (processReader == nil ? OSPermissionAutomation.live:.inactive)
        self.osPermissionMonitoringEnabled=processReader==nil || osPermissionServices != nil
        self.publishedUpdateServices=publishedUpdateServices
        // Injected inventories never inspect the user's real Terminal implicitly.
        if let terminalProfileLayoutReader {self.terminalProfileLayoutReader=terminalProfileLayoutReader}
        else if processReader == nil {self.terminalProfileLayoutReader={try TerminalProfileTopology.read(ttys:$0)}}
        else {self.terminalProfileLayoutReader={_ in []}}
        // Synthetic/injected process inventories have no implicit association
        // with the user's desktop. Tests can supply explicit keyboard activity.
        self.nativeKeyboardActivity = nativeKeyboardActivity ?? (processReader == nil ? .live:.inactive)
        self.cloudflareServices=cloudflareServices
        self.workersServices=workersServices;self.relayServices=relayServices
        self.launchLoopbackOnly = webLoopbackOnly
        self.testScreens = testScreenSharing ?? TestScreenSharing()
        self.managedPTY = managedPTY
        self.powerControl = powerControl
        mouseActivity = MouseActivity(control: mouseActivityControl)
        keepAwakeSwitch = KeepAwakeSwitch(control: powerControl, marker: paths.directory.appendingPathComponent("keep-awake.hold").path)
        var adapters = Dictionary(uniqueKeysWithValues: ScreenHost.allCases.map { ($0, ScreenHostAdapter.live($0, terminalReader:terminalReader)) })
        adapters[.pty] = managedPTY.adapter
        adapters[.tmux] = tmuxRelay.adapter
        if processReader != nil,screenAdapters[.terminal]==nil {adapters[.terminal]?.history=nil}
        self.screenAdapters = adapters.merging(screenAdapters) { _, explicit in explicit }
        self.questionTransport = questionTransport
        self.codexQueue = codexQueue
        self.codexGoals = codexGoals
        self.codexSubagentGoals = codexSubagentGoals
        self.claudeRegistryReader = claudeRegistryReader
        self.processReader = processReader ?? { try ProcessDiscovery.read() }
        self.codexGroupReader = codexGroupReader ?? { record in
            try CodexThreadLocation.locateLive(record)
        }
        self.codexGroupEnvironment = codexGroupEnvironment ?? { ProcessEnvironment.read($0) }
        let modelReader = SessionGroupModelSettingsReader()
        self.groupTranscriptReader = modelReader
        self.groupModelSettingsReader = groupModelSettingsReader ?? { modelReader.read($0) }
        self.profileExecutionSettingsReader = profileExecutionSettingsReader ?? (processReader == nil ? { TerminalProfileExecutionSettingsReader.read($0) } : { _ in nil })
        self.groupClaudeCompletionReader = groupClaudeCompletionReader ?? { modelReader.completion($0, after: $1, task: $2) }
        // Native window checks need one original process, not a system-wide
        // snapshot. Keep injected readers authoritative and every check fresh.
        if let singleProcessReader { self.singleProcessReader = singleProcessReader }
        else if let processReader { self.singleProcessReader = { _ in try processReader() } }
        else { self.singleProcessReader = { try ProcessDiscovery.read(pid: $0) } }
        self.discoveryReader = processReader ?? { try ProcessDiscovery.readSessions() }
        self.remoteProcessVerifier = { session in
            // A first screen already exists in the monitor. Verify its live
            // owner without launching a second process on the handshake path.
            // Custom readers and unsupported/background cases retain ps checks.
            if processReader == nil, let before = try? TTYInputIdentity.capture(pid:session.pid),
               TmuxRelay.currentProcess(pid:session.pid,started:session.started,tty:session.tty,agent:session.agent) != nil {
                guard let after = try? TTYInputIdentity.capture(pid:session.pid), before.sameProcess(as:after) else { return false }
                return true
            }
            let records = try processReader.map { try $0() } ?? ProcessDiscovery.read(pid: session.pid)
            return records.contains {
                $0.pid == session.pid && $0.started == session.started && $0.agent == session.agent && "/dev/" + $0.tty == session.tty
            }
        }
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
        if store.value("networkIsolation") == nil, isolateByDefault,
           store.value("webEnabled") == nil, store.value("webNodeID") == nil {
            // A fresh install starts closed. Existing installs keep their saved LAN setup.
            try? store.set("networkIsolation", "true")
        }
        networkIsolated = store.value("networkIsolation") == "true"
        lanUpdate = Self.idleLANUpdate(enabled: store.value("lanUpdateEnabled") != "false" && !networkIsolated, isolated: networkIsolated)
        snapshot.questionNotificationDelaySeconds = store.value("questionNotificationDelaySeconds").flatMap(Int.init)
        snapshot.codexProgressRecoveryEnabled=store.value("codexProgressRecoveryEnabled") != "false"
        codexAccountTransitionEnabled = store.value("codexAccountTransitionEnabled") == "true"
        if let saved=store.value(Self.codexAccountLoginRequestsKey),let requests=try? JSONDecoder().decode([String:String].self,from:Data(saved.utf8)) {
            var grouped:[String:Set<String>]=[:]
            for (home,id) in requests where UUID(uuidString:id) != nil {
                if let key=try? CodexAccountTransitionTarget.canonicalHome(home) {grouped[key,default:[]].insert(id)}
            }
            // Conflicting aliases do not authorize replay. A fresh explicit
            // login/reconnect replaces them with one canonical receipt.
            codexAccountLoginRequests=grouped.compactMapValues{$0.count==1 ? $0.first:nil}
        }
        if let journal = store.value(Self.codexAccountJournalKey),
           let restored = try? JSONDecoder().decode([String: CodexAccountTransitionState].self, from: Data(journal.utf8)) {
            codexAccountTransitionStates = restored.mapValues { state in
                var copy = state
                if copy.held { copy.phase = .review; copy.detail = "이전 전환 결과를 확인해주세요. 중단·서버 전환 명령을 반복하지 않았습니다." }
                return copy
            }
        }
        keepAwakeEnabled = store.value("keepAwake") == "true"
        mouseActivity.setEnabled(store.value("mouseActivity") == "true")
        snapshot.mouseActivity = mouseActivity.status
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
        if let saved = store.value("interruptedSessions"),
           let values = try? JSONDecoder().decode([SessionExitRecovery].self,from:Data(saved.utf8)) {
            for var value in values.suffix(100) where value.session.interruption?.needsAttention == true &&
                Date().timeIntervalSince(value.session.interruption?.date ?? .distantPast) < 7 * 86400 {
                if value.state == "launching" { value.state = "review"; value.session.interruption?.recoveryStatus = "review" }
                restoreNotificationReceipts(&value.session)
                value.session.phase = .ended; value.session.channel = .none; value.session.automatic = false
                sessions[value.session.id] = value.session; exitRecoveries[value.session.id] = value
            }
        }
        if let saved = store.value("interruptedSessionNotices"),
           let values = try? JSONDecoder().decode([AgentSession].self,from:Data(saved.utf8)) {
            for var value in values.suffix(100) where sessions[value.id] == nil && value.interruption?.needsAttention == true &&
                Date().timeIntervalSince(value.interruption?.date ?? .distantPast) < 7 * 86400 {
                restoreNotificationReceipts(&value)
                sessions[value.id] = value
            }
        }
        configureNativeCodexLogin()
        if let saved=store.value("codexSessionAttachments"),let data=saved.data(using:.utf8),let states=try? JSONDecoder().decode([String:CodexSessionAttachment].self,from:data) {codexSessionAttachments=states.mapValues {var restored=$0;restored.authorizedToolHosts=nil;return restored}}
        if let saved=store.value("codexNativeAttachmentFailures.v1"),let data=saved.data(using:.utf8),let homes=try? JSONDecoder().decode([String].self,from:data) {codexNativeAttachmentFailures=Set(homes)}
        refreshCodexMigrationHolds()
        if let saved=store.value("codexMigrationReconnectContexts.v1"),!saved.isEmpty {
            do {codexMigrationReconnectContexts=try JSONDecoder().decode([String:SessionExitRecovery].self,from:Data(saved.utf8))}
            catch {codexMigrationReconnectRecoveryError=error.localizedDescription}
        }
    }
    private func configureNativeCodexLogin() {
        codexNativeAttachmentTask?.cancel();codexNativeAttachmentTask=nil;codexNativeAttachmentPending.removeAll()
        let accounts=agentAccounts
        accounts.nativeCodexLoginWillStart={ [weak self,weak accounts] target in
            guard let self,let accounts,self.agentAccounts===accounts,!self.remoteInputStopped,!self.codexAccountTransitionBusy,!self.codexAccountTransitionHeld else {throw AppError.message("진행 중인 계정 확인·전환이 끝난 뒤 로그인해주세요.")}
            try self.validateCodexLoginHome(target.home)
        }
        accounts.nativeCodexLoginDidStart={ [weak self,weak accounts] home in
            guard let self,let accounts,self.agentAccounts===accounts,!self.remoteInputStopped else{return}
            self.invalidateCodexAccountInspection(home:home)
        }
        accounts.nativeCodexLoginDidEnd={ [weak self,weak accounts] home in
            guard let self,let accounts,self.agentAccounts===accounts,!self.remoteInputStopped else{return}
            self.invalidateCodexAccountInspection(home:home)
        }
        accounts.nativeCodexLoginCompleted={ [weak self,weak accounts] home in
            guard let self,let accounts,self.agentAccounts === accounts,!self.remoteInputStopped else{return}
            let epoch=self.codexAccountTransitionEpoch
            let loginID=accounts.nativeCodexLogin?.id ?? UUID().uuidString
            self.codexNativeAttachmentPending.insert(home)
            self.codexNativeAttachmentTask?.cancel()
            self.codexNativeAttachmentTask=Task { [weak self,weak accounts] in
                guard let self,let accounts,self.agentAccounts === accounts,!self.remoteInputStopped,self.codexAccountTransitionEpoch==epoch else{return}
                do {
                    self.codexAccountNativeWakePending=true
                    defer {if self.agentAccounts===accounts,self.codexAccountTransitionEpoch==epoch {self.codexNativeAttachmentPending.remove(home);self.codexAccountTransitionSignal.notify()}}
                    try await self.reconnectCodexLogin(home:home,loginRequestID:loginID)
                    self.codexAccountTransitionSignal.notify()
                } catch {
                    guard self.agentAccounts===accounts,!self.remoteInputStopped,self.codexAccountTransitionEpoch==epoch else{return}
                    self.codexNativeAttachmentFailures.insert(home);self.recordedNativeCodexLoginIDs.insert(loginID)
                    try? self.store.set("codexNativeAttachmentFailures.v1",String(decoding:JSONEncoder().encode(Array(self.codexNativeAttachmentFailures).sorted()),as:UTF8.self))
                    self.codexAccountNativeWakePending=false;self.codexAccountTransitionNotice="로그인은 완료됐지만 기존 세션 연결이 보류됐습니다. \(error.localizedDescription)"
                }
            }
        }
    }
    static func connectionGuide(_ session: AgentSession) -> String {
        if session.agent == .agy { return "연결 설정에서 agy 훅을 설치하고 agy 대화를 이어가세요." }
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
        if poll { groupClearDiscoveryReady = false }
        if var state = try? groupOrchestration(), state.removeUndelivered() > 0 { try? saveGroupOrchestration(state) }
        if let state = try? groupOrchestration(), state.needsWatching { scheduleGroupDelivery() }
        refreshGroupWaits()
        if (try? loadGroupClears().contains { !$0.done }) == true { scheduleGroupClears() }
        refreshSessionGroupBadges()
        let socket = SocketServer(path: paths.socket, handler: { [weak self] message, peer in
            Task { @MainActor in self?.receive(message, from: peer) }
        }, disconnected: { [weak self] id in
            Task { @MainActor in self?.disconnect(id) }
        })
        try socket.start(); server = socket; observationEpoch &+= 1
        questionAutomationStopped = false
        keepAwakeStopped = false
        mouseActivity.setEnabled(store.value("mouseActivity") == "true")
        snapshot.mouseActivity = mouseActivity.status
        var confirmations = QuestionConfirmationCache()
        reconcileAutomaticQuestionReplies(duplicatesBySession: duplicateQuestionIDsBySession(), confirmations: &confirmations)
#if DEBUG
        debugQuestionConfirmationDetections += confirmations.detectionCount
#endif
        let savedWeb = store.value("webEnabled")
        if networkIsolated {
            webStatus = Self.isolatedWebStatus
        } else if savedWeb == "true" || (savedWeb == nil && webByDefault) {
            do { try setWebEnabled(true) }
            catch {
                webStatus.enabled = true
                webStatus.detail = "웹 연결을 열지 못했습니다. \(error.localizedDescription)"
            }
        }
        if poll {
            appUpdates.start()
            startCodexAccountTransitionPolling()
            startCodexManagedServerPolling()
            if osPermissionMonitoringEnabled {osPermissionTask=Task { [weak self] in
                while !Task.isCancelled {
                    await self?.refreshOSPermissions()
                    do {try await Task.sleep(for:.seconds(1))} catch {break}
                }
            }}
            pollTask = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.refreshDiscovery()
                    self?.scheduleGoalIntentRecovery()
                    self?.scheduleCohortRecovery()
                    self?.startObservationPolling()
                    do { try await Task.sleep(for: .seconds(4)) } catch { break }
                }
            }
            // The opt-in pulse task sleeps until its one-minute deadline and does not run while disabled.
            startMouseActivityPolling()
            // Screen reads can take many seconds; battery, heat and idle checks keep their own pace.
            let observation = keepAwakeSignal.observe()
            keepAwakeTask = Task { [weak self] in
                await observation.waitForChange(timeout: 0)
                while !Task.isCancelled, let self {
                    await self.evaluateKeepAwake()
                    let interval = KeepAwake.evaluationInterval(enabled: self.keepAwakeEnabled,
                        ownsSleepHold: self.keepAwakeSwitch.owned)
                    await observation.waitForChange(timeout: interval)
                }
            }
        }
    }
    public func stop() {
        groupClearTask?.cancel(); groupClearTask = nil
        groupIdentityObservationTask?.cancel()
        groupConnectionObservation = nil
        groupMCPIdentities.removeAll()
        cohortExecutionTasks.values.forEach{$0.cancel()};cohortExecutionTasks.removeAll()
        goalRecoveryTask?.cancel();goalRecoveryTask=nil
        appUpdates.stop(); updateReceiver.stop()
        groupDeliveryTask?.cancel(); groupDeliveryTask = nil
        groupMailboxTask?.cancel(); groupMailboxTask = nil
        groupMailboxIdleSessions.removeAll()
        groupWaitTimer?.cancel(); groupWaitTimer = nil
        groupBadgeTask?.cancel(); groupBadgeTask = nil
        sessionRestartTasks.values.forEach { $0.cancel() }; sessionRestartTasks.removeAll()
        exitLaunchReads.values.forEach { $0.cancel() }; exitLaunchReads.removeAll()
        for task in codexApprovalTasks.values { task.cancel() };codexApprovalTasks.removeAll();codexApprovalEpochs.removeAll()
        codexAccountTransitionEpoch = UUID()
        for entry in codexAccountInspectionTasks.values {entry.task.cancel()};codexAccountInspectionTasks.removeAll()
        codexAccountInspectionEpochs.removeAll()
        codexNativeAttachmentTask?.cancel();codexNativeAttachmentTask=nil;codexNativeAttachmentPending.removeAll()
        codexAccountTransitionTask?.cancel(); codexAccountTransitionTask = nil
        codexAccountCheckTask?.cancel();codexAccountCheckTask=nil
        codexAccountMembershipRefreshTask?.cancel();codexAccountMembershipRefreshTask=nil
        codexAccountObservedTargets=[];codexAccountMembershipVerifiedAt=nil
        codexManagedServerAutomaticTask?.cancel();codexManagedServerAutomaticTask=nil
        codexManagedServerStartTask?.cancel();codexManagedServerStartTask=nil
        codexAccountTransitionBusy=false;codexAccountNativeWakePending=false
        osPermissionEpoch=UUID()
        osPermissionTransitions.removeAll()
        osPermissionTask?.cancel();osPermissionTask=nil
        accountPINReader.invalidate()
        diagnosticPreparationTask?.cancel()
        for (id,var job) in diagnosticPreparations where job.phase=="running" {job.phase="cancelled";job.message="앱 종료로 진단 준비를 취소했습니다.";diagnosticPreparations[id]=job}
        codexDiagnostics.stop()
        agentAccounts.stop()
        tunnelStartEpoch = UUID()
        tunnelRefreshTask?.cancel();tunnelRefreshTask = nil
        tunnelPINSetupID=nil
        tunnelSetupID=nil
        cloudflareClient?.cancel()
        workersClient?.cancel()
        tunnelController?.stop(waitForExit:true); tunnelController=nil
        relayController?.stop();relayController=nil
        noticeKeyCache = nil
        remoteInputStopped = true
        for id in Array(codexProgressJobs.keys) {cancelCodexProgressCheck(id)}
        codexProgressTrackers.removeAll();codexProgressHistory.removeAll()
        if let history=terminalHistoryStore {Task {await history.stop()};terminalHistoryStore=nil}
        automationRuntime.stop()
        observationEpoch &+= 1
        for pending in claudeHookWaitTasks.values { pending.task.cancel() }; claudeHookWaitTasks.removeAll()
        claudeHookSignals.values.forEach { $0.notify() }; claudeHookSignals.removeAll()
        for pending in ptyContinuationTasks.values { pending.cancel() }
        ptyContinuationTasks.removeAll()
        for observer in ptyLifecycleObservers.values { observer.terminal.removeOutputObserver(observer.token) }
        ptyLifecycleObservers.removeAll()
        managedPTY.stop()
        testScreens.stopAll()
        webQuestions.clear()
        tmuxRelay.stop()
        revision &+= 1; pollTask?.cancel(); pollTask = nil
        historyPollTask?.cancel(); historyPollTask = nil
        for task in screenPollTasks.values { task.cancel() }; screenPollTasks.removeAll()
        gitBranchTask?.cancel(); gitBranchTask = nil
        keepAwakeTask?.cancel(); keepAwakeTask = nil
        mouseActivityTask?.cancel(); mouseActivityTask = nil
        mouseActivity.stop()
        questionAutomationStopped = true
        for id in Array(automaticQuestionReplies.keys) { cancelAutomaticQuestionReply(id) }
        for pending in modelRetentionTasks.values { pending.task.cancel() }; modelRetentionTasks.removeAll()
        manuallyChangedModelQuestions.removeAll()
        retainedModelMenus.removeAll()
        server?.stop(); server = nil
        webService?.stop(); webService = nil
        for pending in remoteInputReplies.values { pending.continuation.resume(throwing: AppError.message("앱이 종료되어 입력 전달 결과를 확인하지 못했습니다.")) }
        for pending in remoteRevealReplies.values { pending.continuation.resume(throwing: AppError.message("앱이 종료되어 원본 창 연결을 확인하지 못했습니다.")) }; remoteRevealReplies.removeAll()
        for pending in remoteScreenReads.values { pending.task.cancel() }
        for pending in remoteInitialReads.values { pending.read.task.cancel() }; remoteInitialReads.removeAll()
        remoteMonitorFrames.removeAll()
        remoteInputReplies.removeAll(); remoteFrames.removeAll(); remoteObservedScreens.removeAll(); remoteScreenReads.removeAll(); remoteStreams.removeAll(); remoteOrcaBindings.removeAll(); screenAnalyses.removeAll(); screenAnalysisCacheBytes = 0
        remoteTerminalChanges.values.forEach { $0.notify() }; remoteTerminalChanges.removeAll()
        for capture in nativeWindowCaptures.values { capture.invalidate() }
        for capture in verifiedWindowCaptures.values { capture.invalidate() }
        for value in bridgeWindowCaptures.values { value.capture.invalidate() }; bridgeWindowCaptures.removeAll()
        // Quitting gives macOS its normal sleep back, without putting a closed Mac to sleep.
        keepAwakeStopped = true
        if !lanUpdateSleepTransferred { keepAwakeSwitch.releaseNow() }
        setKeepAwakeActivity(false)
    }

    static var isolatedWebStatus: RemoteNetworkStatus {
        var status = RemoteNetworkStatus()
        status.detail = "네트워크 격리 모드라 웹 서버가 꺼져 있습니다."
        return status
    }
    public func setWebEnabled(_ enabled: Bool, port: UInt16? = nil, bonjourEnabled: Bool = true, discoveryAddresses: (() -> [String])? = nil) throws {
        if enabled {
            guard !networkIsolated else { throw AppError.message("네트워크 격리 모드에서는 웹 서버를 켤 수 없습니다. 격리를 끄면 다시 켤 수 있습니다.") }
            if webService != nil {
                guard port != nil else { return }
                tunnelController?.stop(); tunnelController=nil; tunnelRestoreAttempted=false
                relayController?.stop();relayController=nil
                webService?.stop(); webService = nil
            }
            let nodeID = store.value("webNodeID") ?? UUID().uuidString
            try store.set("webNodeID", nodeID)
            let service = RemoteNetworkService(engine: self, nodeID: nodeID, bonjourEnabled: bonjourEnabled, loopbackOnly: webLoopbackOnly, discoveryAddresses: discoveryAddresses) { [weak self] status in
                guard let self else { return }
                self.webStatus = status
                if status.ready, let actualPort = status.port { try? self.store.set("webPort", String(actualPort)) }
                if status.ready { self.restoreTunnelIfRequested() }
            }
            let preferredPort = port ?? store.value("webPort").flatMap(UInt16.init) ?? 8765
            try service.start(port: preferredPort, allowPortFallback: port == nil)
            do { try store.set("webEnabled", "true") }
            catch { service.stop(); throw error }
            webService = service
        } else {
            try stopTunnel()
            try store.set("webEnabled", "false")
            testScreens.stopAll()
            webService?.stop(); webService = nil
        }
    }

    public func setLANUpdateEnabled(_ enabled: Bool) throws {
        try store.set("lanUpdateEnabled", enabled ? "true" : "false")
        let active = enabled && !networkIsolated
        if !active { webService?.cancelLANUpdate() }
        lanUpdate = Self.idleLANUpdate(enabled: active, isolated: networkIsolated)
    }
    private static func idleLANUpdate(enabled: Bool, isolated: Bool) -> LANUpdateStatus {
        var value = LANUpdateStatus(); value.enabled = enabled
        if !enabled {
            value.phase = "off"
            value.detail = isolated ? "네트워크 격리 모드라 같은 네트워크의 자동 업데이트가 꺼져 있습니다." : "같은 네트워크의 자동 업데이트가 꺼져 있습니다."
        }
        return value
    }
    /// Turn shared-computer isolation on or off. Turning it on stops the web
    /// server, LAN discovery, peer links, LAN updates and external tunnels
    /// before returning; the saved web preference is kept. Turning it off
    /// restores the web server unless the user had switched it off; a stopped
    /// tunnel stays off until the user starts it again.
    public func setNetworkIsolation(_ enabled: Bool) throws {
        guard enabled != networkIsolated else { return }
        try store.set("networkIsolation", enabled ? "true" : "false")
        networkIsolated = enabled
        lanUpdate = Self.idleLANUpdate(enabled: store.value("lanUpdateEnabled") != "false" && !enabled, isolated: enabled)
        if enabled {
            appUpdates.stop()
            try? stopTunnel()
            testScreens.stopAll()
            webService?.cancelLANUpdate()
            webService?.stop(); webService = nil
            webStatus = Self.isolatedWebStatus
        } else {
            webStatus = RemoteNetworkStatus()
            if store.value("webEnabled") != "false" { try setWebEnabled(true) }
            appUpdates.start()
        }
    }
    func updateLANUpdateStatus(_ value: LANUpdateStatus) {
        if lanUpdate != value { lanUpdate = value }; appUpdates.receive(value)
    }
    var lanUpdateWaitReason: String? {
        updateWaitReason(allowTunnelRestart:false)
    }
    func updateWaitReason(allowTunnelRestart:Bool) -> String? {
        if cloudflareStatus.busy || tunnelPINSetupID != nil {return "외부 접속 설정 중이라 업데이트를 기다립니다. 설정을 마치면 적용합니다."}
        if tunnelStatus.active && (!allowTunnelRestart || tunnelStatus.provider == .quick) { return tunnelStatus.provider == .quick && allowTunnelRestart ? "임시 주소는 앱 재시작 시 바뀝니다. Mac에서 임시 연결을 종료하면 업데이트합니다." : "외부 터널이 연결되어 업데이트를 기다립니다. 연결을 종료하면 적용합니다." }
        if codexDiagnostics.busy || diagnosticCollectingRequest != nil {return "Codex 진단이 진행 중입니다. 완료하거나 취소한 뒤 업데이트합니다."}
        if agentAccounts.busy {return "AI 계정 로그인이 진행 중입니다. 인증을 마치거나 취소한 뒤 업데이트합니다."}
        if managedPTY.inventory.contains(where: { (try? managedPTY.terminal($0.ptyID).isRunning) == true }) { return "별도 PTY가 실행 중이라 업데이트를 기다립니다. 원본 터미널은 계속 실행됩니다." }
        if !remoteInputSessions.isEmpty || !remotePTYInput.isEmpty || !automaticInputSessions.isEmpty ||
            !sendingMessages.isEmpty || !replyingQuestions.isEmpty || !clearingCodexQueues.isEmpty ||
            !remoteInputReplies.isEmpty || automaticQuestionReplies.values.contains(where: { $0.sending }) ||
            remoteInputUntil.values.contains(where: { $0 > Date() }) {
            return "입력 전송이 끝난 뒤 업데이트합니다."
        }
        if !webQuestions.pending().isEmpty || !testScreens.active.isEmpty { return "웹 질문과 화면 공유가 끝난 뒤 업데이트합니다." }
        return nil
    }

    public func remoteSessionViews() -> [RemoteSessionView] {
        let candidates = snapshot.sessions.filter { $0.phase != .ended || $0.interruption?.needsAttention == true ||
            ($0.interruption?.resumedSessionID != nil && Date().timeIntervalSince($0.interruption?.recoveredAt ?? .distantPast) < 300) }
        // The helper status is shared by every Terminal tab. Read its cached
        // state lazily once per inventory instead of locking the XPC client for
        // each session or probing it when no readable Terminal tab exists.
        var terminalKeysAvailable: Bool?
        return candidates.compactMap { session -> RemoteSessionView? in
            let canRead = remoteCanRead(session) || nativeWindowCapture(for: session) != nil || usesOrcaSnapshot(session)
            let ptyID = session.id.hasPrefix("pty:") ? String(session.id.dropFirst(4)) : ptySessionBindings[session.id]
            let terminal = ptyID.flatMap { try? managedPTY.terminal($0) }
            if let terminal, !terminal.isRunning { return nil }
            let pty = terminal?.descriptor
            let keys: [String]
            if canRead && (!usesOrcaSnapshot(session) || remoteCanRead(session)) {
                if session.terminal == .terminal {
                    if terminalKeysAvailable == nil { terminalKeysAvailable = self.terminalInputAvailable() }
                    keys = remoteKeys(session, terminalInputAvailable: terminalKeysAvailable)
                } else { keys = remoteKeys(session) }
            } else { keys = [] }
            return RemoteSessionView(session: session,
                title: session.customization?.title.isEmpty == false ? session.customization!.title : session.terminalTitle ?? session.project,
                phaseTitle: session.phaseTitle, canApprove: session.canApprove, canReveal: session.canReveal,
                canRead: canRead, inputReason: remoteInputReason(session), keys: keys,
                ptyID: pty?.ptyID, pty: pty)
        }
    }
    public func remoteHistory(sessionID: String) throws -> [AuditEvent] {
        guard let session = snapshot.sessions.first(where:{$0.id == sessionID}) else { throw RemoteHTTPError(404,"세션을 찾을 수 없습니다.") }
        let members = Set([session.id]+session.backgroundChildren.map(\.id))
        return Array(snapshot.events.filter {members.contains($0.sessionID) || $0.originSessionID.map(members.contains) == true}.prefix(12))
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
    /// Prefer the exact live rollout. A daemon-backed TUI can also bind a unique
    /// full server name to its current terminal title; unresolved rows keep a picker.
    public func terminalProfileCandidates(includeLayout:Bool = true) async throws -> [TerminalProfileCandidate] {
        guard !remoteInputStopped else {throw AppError.message("앱이 종료 중입니다.")}
        let targets=snapshot.sessions.filter {$0.agent != .shell && $0.phase != .ended && $0.pid>0}
        guard targets.count<=128 else {throw AppError.message("프로필에는 최대 128개 세션을 저장합니다.")}
        let reader=processReader,registry=claudeRegistryReader
        let live=try await Task.detached(priority:.utility) {try reader()}.value
        var result:[TerminalProfileCandidate]=[]
        // The same exact identities are needed for saving and deduplicating
        // restoration. Share only this operation's home/folder lookup.
        var conversationLists:[String:[String:[CodexQueueConversation]]]=[:]
        var namedCodexBindings:[String:String]=[:]
        var layoutNamedBindings=Set<String>()
        var explicitCodexBindings:[String:String]=[:]
        for session in targets {
            try Task.checkCancellation()
            guard let record=live.first(where:{$0.key == session.id && $0.agent == session.agent && "/dev/"+$0.tty == session.tty}) else {
                throw AppError.message("세션 목록이 바뀌었습니다. 현재 창을 다시 불러와주세요.")
            }
            let environment=await Task.detached(priority:.utility) {ProcessEnvironment.read(record) ?? [:]}.value
            let title=String(session.displayedTerminalTitle.components(separatedBy:.newlines).joined(separator:" ").unicodeScalars.filter {!CharacterSet.controlCharacters.contains($0)}.map(String.init).joined().prefix(256))
            var entry=TerminalProfileEntry(title:title,agent:session.agent.rawValue,cwd:session.cwd,conversationID:"",
                providerHome:environment[session.agent == .codex ? "CODEX_HOME":"CLAUDE_CONFIG_DIR"],host:session.terminal == .iterm ? .iterm:.terminal)
            var choices:[CodexProfileConversation]=[],detail:String?
            if session.agent == .codex {
                let location=try? await Task.detached(priority:.utility) {
                    try CodexThreadLocation.locate(paths:ProcessOpenFiles.codexRolloutPaths(pid:record.pid,expectedStart:record.started))
                }.value
                if let location {
                    entry.conversationID=location.threadID
                    entry.providerHome=URL(fileURLWithPath:location.database).deletingLastPathComponent().path
                } else {
                    do {
                        let target=try await questionTransport.queueHome(session)
                        entry.providerHome=target.home
                        if let thread=session.codexApprovalBinding?.threadID,UUID(uuidString:thread) != nil {
                            var bound=target;bound.threadID=thread
                            try await codexQueue.validate(bound,session.cwd)
                            entry.conversationID=thread
                            explicitCodexBindings[session.id]=thread
                        }
                        if entry.conversationID.isEmpty || includeLayout {
                            let conversations:[CodexQueueConversation]
                            if let cached=conversationLists[target.home]?[session.cwd] {conversations=cached}
                            else {
                                conversations=try await codexQueue.conversations(target,session.cwd)
                                conversationLists[target.home,default:[:]][session.cwd]=conversations
                            }
                            if includeLayout {choices=conversations.map {CodexProfileConversation(id:$0.id,title:$0.title)}}
                            if entry.conversationID.isEmpty,let bound=CodexProfileConversationBinding.match(title:session.terminalTitle,cwd:session.cwd,conversations:conversations),let name=bound.name {
                                entry.conversationID=bound.id
                                namedCodexBindings[session.id]=name.precomposedStringWithCanonicalMapping
                            }
                        }
                        if entry.conversationID.isEmpty {detail="현재 대화를 확인하지 못했습니다. 이어갈 대화를 선택하거나 새 CLI 실행을 명시적으로 선택해주세요."}
                    } catch {detail="현재 대화를 확인하지 못했습니다: "+error.localizedDescription}
                }
            } else {
                let home=entry.providerHome
                let rows=await Task.detached(priority:.utility) {
                    home.map {ClaudeSessionRegistry.read(records:[record],directory:URL(fileURLWithPath:$0))} ?? registry([record])
                }.value
                let identities=Set(rows.filter {$0.processID == session.id}.compactMap(\.conversationID))
                if identities.count == 1,let id=identities.first,UUID(uuidString:id) != nil {entry.conversationID=id}
                else if let id=session.providerID,UUID(uuidString:id) != nil {entry.conversationID=id}
                else {detail="대화 ID는 선택 사항입니다. 비워 두면 이 폴더에서 새 Claude Code를 엽니다."}
            }
            if ![TerminalKind.terminal,.iterm].contains(session.terminal) {
                detail=(detail.map {$0+" "} ?? "")+"이 세션은 새 Terminal 창에서 복원합니다."
            }
            result.append(.init(id:session.id,entry:entry,conversations:choices,detail:detail,tty:session.terminal == .terminal ? session.tty:nil))
        }
        let terminalTTYs=result.filter {$0.entry.host == .terminal}.compactMap(\.tty),layoutReader=terminalProfileLayoutReader
        if includeLayout && !terminalTTYs.isEmpty {
            let layout=try await Task.detached(priority:.utility) {try layoutReader(terminalTTYs)}.value
            result=try TerminalProfileTopology.apply(layout,to:result)
            for index in result.indices where result[index].entry.agent == "codex" {
                let candidate=result[index]
                guard let title=candidate.entry.terminalTab?.customTitle,!title.isEmpty,
                      let home=candidate.entry.providerHome,
                      let conversations=conversationLists[home]?[candidate.entry.cwd] else {continue}
                // Terminal's freshly read title can be newer than the polling
                // snapshot (notably immediately after startup or /resume).
                if let bound=CodexProfileConversationBinding.match(title:title,cwd:candidate.entry.cwd,conversations:conversations),let name=bound.name {
                    if !candidate.entry.conversationID.isEmpty,namedCodexBindings[candidate.id]==nil,
                       UUID(uuidString:candidate.entry.conversationID) != UUID(uuidString:bound.id) {
                        throw AppError.message("대화 연결과 현재 Terminal 탭이 다릅니다. 현재 대화를 다시 확인해주세요.")
                    }
                    result[index].entry.conversationID=bound.id
                    result[index].detail=nil
                    namedCodexBindings[candidate.id]=name.precomposedStringWithCanonicalMapping
                    layoutNamedBindings.insert(candidate.id)
                } else if namedCodexBindings[candidate.id] != nil {
                    throw AppError.message("대화를 확인하는 동안 Terminal 탭 제목이 바뀌었습니다. 다시 저장해주세요.")
                }
            }
        }
        if includeLayout {
            let settingsReader = profileExecutionSettingsReader
            for index in result.indices {
                let entry = result[index].entry
                guard let session = targets.first(where: { $0.id == result[index].id }), UUID(uuidString: entry.conversationID) != nil else { continue }
                let home = entry.providerHome ?? NSHomeDirectory() + (entry.agent == "codex" ? "/.codex" : "/.claude")
                let settingsTarget = SessionGroupLiveSession(session: session, conversationID: entry.conversationID, providerHome: home)
                result[index].entry.executionSettings = await Task.detached(priority: .utility) { settingsReader(settingsTarget) }.value
                if result[index].entry.executionSettings == nil || (entry.agent == "codex" && result[index].entry.executionSettings?.serviceTier == nil) {
                    result[index].detail = (result[index].detail.map { $0 + " " } ?? "") + "일부 실행 설정을 확인하지 못했습니다. 저장 화면에서 모델·추론 수준·처리 속도를 확인해주세요."
                }
            }
        }
        let fresh=try await Task.detached(priority:.utility) {try reader()}.value
        guard !remoteInputStopped,result.allSatisfy({candidate in
            guard let original=targets.first(where:{$0.id == candidate.id}),let current=sessions[candidate.id] else {return false}
            if let thread=explicitCodexBindings[candidate.id],current.codexApprovalBinding?.threadID != thread {return false}
            if let name=namedCodexBindings[candidate.id] {
                let matches=CodexProfileConversationBinding.terminalName(current.terminalTitle,cwd:current.cwd)==name
                guard matches || (layoutNamedBindings.contains(candidate.id) && current.terminalTitle==original.terminalTitle) else {return false}
                if let title=candidate.entry.terminalTab?.customTitle,!title.isEmpty,
                   CodexProfileConversationBinding.terminalName(title,cwd:current.cwd) != name {return false}
            }
            return current.pid == original.pid && current.started == original.started && current.cwd == original.cwd &&
                fresh.contains(where:{$0.key == original.id && $0.agent == original.agent && "/dev/"+$0.tty == original.tty})
        }) else {throw AppError.message("대화를 확인하는 동안 창이 바뀌었습니다. 현재 세션을 다시 불러와주세요.")}
        return result
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
        return registrations.count == 1 ? registrations.first?.conversationID : nil
    }
    private func spawnPTY(_ object: JSONObject) async throws -> ManagedPTYDescriptor {
        guard !remoteInputStopped else { throw RemoteHTTPError(503, "앱이 종료 중입니다.") }
        var cwd = object["cwd"] as? String ?? NSHomeDirectory()
        var program = object["program"] as? String ?? "shell"
        var command: [String]?
        var codexContext:CodexCLIContext?
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
            // Fork the recorded conversation, preserving the original running TUI.
            // Without an exact ID, open the provider's picker; never choose --last.
            if session.agent == .codex {
                let context=try await Task.detached(priority:.utility) {try CodexOfficialExecutable.forSession(record)}.value
                codexContext=context
                command=try context.terminalInvocation(["fork"]+(conversation.map{[$0]} ?? []))
            } else {
                command=[record.executable,"--resume"]+(conversation.map{[$0]} ?? [])+["--fork-session"]
            }
            let fresh = try await Task.detached { try reader() }.value
            guard !remoteInputStopped, fresh.contains(where: { $0.key == record.key && $0.agent == session.agent && "/dev/" + $0.tty == session.tty }), sessions[id]?.pid == session.pid else { throw RemoteHTTPError(409, "원래 CLI가 종료되었거나 바뀌었습니다.") }
        }
        try Task.checkCancellation()
        let manager=managedPTY,launchCwd=cwd,launchProgram=program,launchCommand=command,launchContext=codexContext
        let columns=object["columns"] as? Int ?? 80,rows=object["rows"] as? Int ?? 24
        let creation=Task.detached(priority:.userInitiated) {
            try launchContext?.verifyUnchanged()
            return try manager.create(cwd:launchCwd,program:launchProgram,command:launchCommand,columns:columns,rows:rows,environment:launchContext?.environment)
        }
        let terminal=try await withTaskCancellationHandler(operation:{try await creation.value},onCancel:{creation.cancel()})
        guard !remoteInputStopped,!Task.isCancelled else {
            (try? manager.terminal(terminal.ptyID))?.close();throw CancellationError()
        }
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
    func validateInputChannel(_ object:JSONObject) throws -> JSONObject {
        guard !remoteInputStopped, let binding = try? RemoteInputBinding(JSONSerialization.data(withJSONObject:object)) else { throw RemoteInputPacket.invalid() }
        if binding.mode == "pty" {
            let terminal = try managedPTY.terminal(binding.values["ptyID"] as! String)
            try terminal.validateInputBinding(streamID:binding.values["streamID"] as! String,client:binding.values["clientID"] as! String,sequence:binding.sequenceBase)
        } else {
            let id = binding.values["sessionID"] as! String, stream = binding.values["streamID"] as! String
            guard let session = sessions[id],session.phase != .ended,let observed = remoteFrames[id],
                  observed.frame.streamID == stream,remoteStreams[id]?.token == stream,remoteStreams[id]?.generation == observed.generation,
                  Date().timeIntervalSince(observed.frame.observedAt) < 10,observed.frame.inputReason == nil,remoteInputReason(session) == nil else {
                throw RemoteHTTPError(409,"원본 터미널의 실시간 연결을 먼저 확인해주세요.")
            }
        }
        return ["accepted":true]
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
            if sessions[key]?.queuedQuestions?.isEmpty == false { invalidateDuplicateQuestionIDs() }
            sessions[key]?.queuedQuestions = []; sessions[key]?.codexQuestionsError = nil
            clearScreen(key); capacityStates.removeValue(forKey: key)
        }
        ptyAutomatic[id] = false
        synchronizePTYContainers(); publish()
    }
    private func remoteCanRead(_ session: AgentSession) -> Bool {
        guard session.phase != .ended else { return false }
        if let host = ScreenHost(kind: session.terminal) { return screenConnections[host]?.enabled == true && screenConnections[host]?.permissionBlocked != true && !session.tty.isEmpty }
        return session.terminal == .vscode && session.bridgeID != nil && (remoteObservedScreens[session.id] != nil || nativeBridgeBinding(session) != nil)
    }
    public func remoteTmuxObservation(sessionID: String) throws -> TmuxRelayObservation? {
        guard let session = sessions[sessionID], session.terminal == .tmux, remoteCanRead(session) else { return nil }
        return try tmuxRelay.observe(ScreenTarget(tty: session.tty, handle: session.tmuxHandle))
    }
    private func usesOrcaSnapshot(_ session: AgentSession) -> Bool { session.terminal == .orca && orcaSnapshotReader != nil }
    private func remoteKeys(_ session: AgentSession, terminalInputAvailable inputAvailable: Bool? = nil) -> [String] {
        let basic = ["text", "enter", "escape", "interrupt", "up", "down", "tab"]
        let interactive = ["submit", "characters", "left", "right", "backspace", "delete", "home", "end", "choice"]
        if session.terminal == .terminal {
            return (inputAvailable ?? terminalInputAvailable()) ? basic + interactive + ["message"] : ["text", "submit", "enter"]
        }
        if session.terminal == .tmux { return basic + interactive + ["message"] }
        if usesOrcaSnapshot(session) {
            return ["characters", "enter", "escape", "interrupt", "up", "down", "left", "right", "backspace", "delete", "home", "end", "tab", "choice"]
        }
        if session.terminal == .vscode {
            let registration = session.bridgeID.flatMap { bridges[$0] }?.first { $0["id"] as? String == session.terminalID }
            return basic + ((registration?["remoteInputVersion"] as? Int ?? 0) >= 2 ? interactive.filter { $0 != "choice" || registration?["choiceInput"] as? Bool == true } : [])
        }
        return basic + interactive
    }
    private func remoteInputReason(_ session: AgentSession) -> String? {
        if codexAccountInputHeld(session.id) { return Self.codexAccountHoldMessage }
        if !remoteCanRead(session) { return "이 세션의 화면 연결이 없습니다. Mac의 연결 설정에서 터미널을 연결해주세요. 훅으로 받은 질문은 아래에서 답할 수 있습니다." }
        if session.terminal == .vscode {
            let registration = session.bridgeID.flatMap { bridges[$0] }?.first { $0["id"] as? String == session.terminalID }
            if (registration?["remoteInputVersion"] as? Int ?? 0) < 1 { return "Mac에서 AutoApprove Bridge 확장을 업데이트하면 웹에서 입력할 수 있습니다." }
        }
        return nil
    }

    private func readRemoteScreen(_ session: AgentSession, host: ScreenHost, adapter: ScreenHostAdapter,
                                  realtime: Bool = false, initial: Bool = false, textOnly: Bool = false) async throws -> RemoteObservedScreen {
        let target = ScreenTarget(tty: session.tty, handle: session.screenHandle)
        let generation = remoteGeneration(session, host: host)
        if textOnly {
            // Group delivery validates fresh text from this exact TTY. Cursor,
            // title and selected-window decoration must not gate a message.
            // Keep it out of the viewer cache so neither read can replace the other.
            let snapshot = try await Task.detached(priority: .userInitiated) {
                try RemoteTerminalPerformance.shared.measure(.textRead) {
                    try adapter.readForValidation([target])
                }
            }.value
            try Task.checkCancellation()
            guard let screen = snapshot.screens.first(where: { $0.tty == target.tty }) else {
                throw RemoteHTTPError(503, snapshot.failures.first?.message ?? "원본 터미널의 입력 확인용 텍스트를 읽지 못했습니다.")
            }
            return RemoteObservedScreen(raw: screen.contents, generation: generation, observedAt: Date(),
                                        appearance: nil, cursor: nil, display: nil)
        }
        // A new subscriber still checks permission and the original process.
        // Reuse only a completed live observation within the live cache's own
        // freshness window; never join a slow pending presentation read here.
        if initial, host == .terminal, !userInputHasPriority(session.id),
           let pending=remoteScreenReads[session.id],pending.target==target,pending.generation==generation,
           !pending.task.isCancelled,let at=pending.observedAt,
           (0..<0.18).contains(Date().timeIntervalSince(at)),
           pending.sourceRevision==remoteTerminalChanges[session.id]?.revision {
            let verifier=remoteProcessVerifier
            let verified=try await Task.detached(priority:.userInitiated) {
                try RemoteTerminalPerformance.shared.measure(.identity) {try verifier(session)}
            }.value
            guard verified,!remoteInputStopped,let current=sessions[session.id],current.phase != .ended,
                  remoteGeneration(current,host:host)==generation,remoteCanRead(current) else {
                throw RemoteHTTPError(409,"원본 터미널 연결이 바뀌었습니다. 다시 연결해주세요.")
            }
            let observed=try await pending.task.value
            try Task.checkCancellation()
            guard !remoteInputStopped,let latest=sessions[session.id],latest.phase != .ended,
                  remoteGeneration(latest,host:host)==generation,remoteCanRead(latest) else {
                throw RemoteHTTPError(409,"원본 터미널 연결이 바뀌었습니다. 다시 연결해주세요.")
            }
            if remoteScreenReads[session.id]?.token==pending.token,pending.observedAt==at,
               !userInputHasPriority(session.id),(0..<0.18).contains(Date().timeIntervalSince(at)),
               pending.sourceRevision==remoteTerminalChanges[session.id]?.revision {
                RemoteTerminalPerformance.shared.increment(.initialLiveCacheHits)
                return observed
            }
        }
        // The monitor already read this exact original process. Only the first
        // subscription can use it, with its real timestamp; later frames and
        // input-triggered reads retain the tighter live-read cache.
        if initial, !userInputHasPriority(session.id), [.terminal, .iterm].contains(host),
           let observed = remoteMonitorFrames[session.id], observed.generation == generation,
           (0..<2).contains(Date().timeIntervalSince(observed.observedAt)) {
            let verifier = remoteProcessVerifier
            let verified = try await Task.detached(priority:.userInitiated) {
                try RemoteTerminalPerformance.shared.measure(.identity) { try verifier(session) }
            }.value
            guard verified, let current = sessions[session.id], current.phase != .ended,
                  remoteGeneration(current, host: host) == generation, remoteCanRead(current),
                  remoteMonitorFrames[session.id]?.generation == generation else {
                throw RemoteHTTPError(409, "원본 터미널 연결이 바뀌었습니다. 다시 연결해주세요.")
            }
            return observed
        }
        let verifier = remoteProcessVerifier
        func read(using reader: @escaping @Sendable ([ScreenTarget]) throws -> TerminalSnapshot,
                  stage: RemoteTerminalPerformance.Stage, verifyOriginal: Bool = false) -> Task<RemoteObservedScreen,Error> {
            Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                if verifyOriginal, try !RemoteTerminalPerformance.shared.measure(.identity,{try verifier(session)}) {
                    throw RemoteHTTPError(409,"원본 터미널 연결이 바뀌었습니다. 다시 연결해주세요.")
                }
                return try RemoteTerminalPerformance.shared.measure(stage) {
                try Task.checkCancellation()
                let snapshot: TerminalSnapshot
                do { snapshot = try reader([target]) }
                catch let error as TerminalAdapterError { throw error }
                catch let error as RemoteHTTPError { throw error }
                catch is CancellationError { throw CancellationError() }
                catch {
                    throw RemoteHTTPError(503, "원본 터미널 화면을 일시적으로 읽지 못했습니다. 같은 세션에 다시 연결합니다.")
                }
                guard let screen = snapshot.screens.first(where: { $0.tty == target.tty }) else {
                    throw RemoteHTTPError(503, snapshot.failures.first?.message ?? "원본 터미널 화면을 일시적으로 읽지 못했습니다. 같은 세션에 다시 연결합니다.")
                }
                return RemoteObservedScreen(raw: screen.contents, generation: generation, observedAt: Date(), appearance: screen.appearance?.validated(for: screen.contents), cursor: screen.cursor?.validated(for: screen.contents), display: screen.display?.validated())
                }
            }
        }
        // A cold text subscription must not wait for JXA/Accessibility cursor
        // collection or join another viewer's slow presentation read. Read the
        // current text directly, then let the live stream obtain presentation.
        // Keeping this out of the live cache also prevents suppressing that read.
        if initial, host == .terminal, adapter.presentationScreens != nil, !userInputHasPriority(session.id) {
            let waiter = UUID(), pending: RemoteScreenRead
            if let existing = remoteInitialReads[session.id], existing.read.target == target,
               existing.read.generation == generation, !existing.read.task.isCancelled {
                pending = existing.read; remoteInitialReads[session.id]?.waiters.insert(waiter)
                RemoteTerminalPerformance.shared.increment(.sharedInitialReads)
            } else {
                cancelRemoteInitialRead(session.id)
                pending = RemoteScreenRead(token:UUID(),target:target,generation:generation,
                    task:read(using:adapter.initialScreens ?? adapter.screens,stage:.textRead,verifyOriginal:true))
                remoteInitialReads[session.id] = RemoteInitialRead(read:pending,waiters:[waiter])
                RemoteTerminalPerformance.shared.increment(.initialReads)
            }
            defer { releaseRemoteInitialRead(session.id,token:pending.token,waiter:waiter) }
            do {
                let observed = try await withTaskCancellationHandler(operation:{try await pending.task.value},onCancel:{
                    Task { @MainActor [weak self] in self?.releaseRemoteInitialRead(session.id,token:pending.token,waiter:waiter) }
                })
                if remoteInitialReads[session.id]?.read.token == pending.token { remoteInitialReads[session.id]?.read.observedAt = observed.observedAt }
                try Task.checkCancellation()
                guard remoteInitialReads[session.id]?.read.token == pending.token, !remoteInputStopped,
                      let current = sessions[session.id], remoteGeneration(current,host:host) == generation, remoteCanRead(current) else {
                    throw initialReadChangeError(sessionID:session.id,host:host,generation:generation)
                }
                return observed
            } catch {
                try Task.checkCancellation()
                guard remoteInitialReads[session.id]?.read.token == pending.token else {
                    throw initialReadChangeError(sessionID:session.id,host:host,generation:generation)
                }
                throw error
            }
        }
        let pending: RemoteScreenRead
        let cacheAge: TimeInterval = remoteUserInputHasPriority(session.id) ? 0.12 : realtime ? 0.18 : Self.remoteReadCacheLifetime
        let sourceRevision = host == .tmux ? tmuxRelay.sourceRevision(target) : remoteTerminalChanges[session.id]?.revision
        if let existing = remoteScreenReads[session.id], existing.target == target, existing.generation == generation,
           existing.observedAt.map({ existing.sourceRevision == sourceRevision && Date().timeIntervalSince($0) < cacheAge }) ?? true {
            pending = existing
        } else {
            let task = read(using:adapter.presentationScreens ?? adapter.screens,
                stage:adapter.presentationScreens == nil ? .textRead : .presentationRead)
            pending = RemoteScreenRead(token: UUID(), target: target, generation: generation, task: task)
            pending.sourceRevision = sourceRevision
            remoteScreenReads[session.id] = pending
        }
        pending.activeReaders += 1
        defer { pending.activeReaders -= 1 }
        do {
            let observed = try await pending.task.value
            guard remoteScreenReads[session.id]?.token == pending.token else {
                throw RemoteHTTPError(409, "화면 연결이나 입력 상태가 바뀌었습니다. 최신 화면을 다시 확인해주세요.", diagnostics:["failureKind":"observationChanged"])
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
        let cacheAge: TimeInterval = remoteUserInputHasPriority(session.id) ? 0.12 : realtime ? 0.18 : Self.remoteReadCacheLifetime
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
        pending.activeReaders += 1
        defer { pending.activeReaders -= 1 }
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
        cancelRemoteInitialRead(id)
        // A concurrent reader still owns its token; do not turn a valid live read into a disconnect.
        if remoteScreenReads[id]?.observedAt != nil { remoteScreenReads[id]?.observedAt = .distantPast }
        remoteTerminalChanges[id]?.notify()
    }
    private func cancelRemoteInitialRead(_ id: String) {
        if let pending = remoteInitialReads.removeValue(forKey:id) {
            if pending.read.observedAt == nil { RemoteTerminalPerformance.shared.increment(.abandonedInitialReads) }
            pending.read.task.cancel()
        }
    }
    private func initialReadChangeError(sessionID: String, host: ScreenHost, generation: String) -> RemoteHTTPError {
        if !remoteInputStopped, let current = sessions[sessionID], remoteGeneration(current,host:host) == generation, remoteCanRead(current) {
            return RemoteHTTPError(409,"화면 연결이나 입력 상태가 바뀌었습니다. 최신 화면을 다시 확인해주세요.",diagnostics:["failureKind":"observationChanged"])
        }
        return RemoteHTTPError(409,"원본 터미널 연결이 바뀌었습니다. 다시 연결해주세요.")
    }
    private func releaseRemoteInitialRead(_ id: String, token: UUID, waiter: UUID) {
        guard remoteInitialReads[id]?.read.token == token else { return }
        remoteInitialReads[id]?.waiters.remove(waiter)
        if remoteInitialReads[id]?.waiters.isEmpty == true { cancelRemoteInitialRead(id) }
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
        let reader = singleProcessReader, pid = session.pid, started = session.started, tty = session.tty.replacingOccurrences(of: "/dev/", with: ""), agent = session.agent.rawValue
        return {
            try reader(pid).contains { $0.pid == pid && $0.started == started && $0.tty == tty && $0.agent?.rawValue == agent && $0.isForeground }
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

    public func remoteTerminal(sessionID: String, realtime: Bool = false, renderWindow: Bool = false,
                               initial: Bool = false, textOnly: Bool = false) async throws -> RemoteTerminalFrame {
        let frameStart = RemoteTerminalPerformance.now; var frameSucceeded = false
        defer { RemoteTerminalPerformance.shared.observe(initial ? .firstFrame : .liveFrame,
            elapsed:RemoteTerminalPerformance.now-frameStart,succeeded:frameSucceeded) }
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
        var automationBlocked = false
        if [.terminal,.iterm].contains(session.terminal), let sourceCapture {
            let permissionStart = RemoteTerminalPerformance.now; var permissionSucceeded = false
            defer { RemoteTerminalPerformance.shared.observe(.automation,elapsed:RemoteTerminalPerformance.now-permissionStart,succeeded:permissionSucceeded) }
            automationBlocked = try await !sourceCapture.checkAutomationPermission()
            permissionSucceeded = true
            guard !remoteInputStopped, let current = sessions[sessionID], current.phase != .ended,
                  current.pid == session.pid, current.started == session.started, current.tty == session.tty,
                  current.terminal == session.terminal, nativeWindowCapture(for:current) === sourceCapture else {
                throw RemoteHTTPError(409,"원본 터미널 연결이 바뀌었습니다. 다시 연결해주세요.")
            }
        }
        if automationBlocked {
            if renderWindow { nativeDisplay = capture?.permissionState() ?? TerminalNativeDisplay(state: .permissionRequired, message: "Mac에서 원래 터미널의 자동화 권한을 허용한 뒤 연결해주세요.") }
        }
        let raw: String, generation: String, observedAt: Date, appearance: TerminalAppearance?, cursor: TerminalCursor?
        var orcaBinding: RemoteOrcaBinding?, sourceReason: String?, outputReason: String?, display: TerminalTextSnapshot?
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
            let observed = try await readRemoteScreen(session, host: host, adapter: adapter, realtime: realtime, initial: initial && !renderWindow, textOnly: textOnly)
            raw = observed.raw; generation = observed.generation; observedAt = observed.observedAt
            appearance = observed.appearance; cursor = observed.cursor
            display = observed.display
        } else {
            guard let observed = remoteObservedScreens[sessionID], Date().timeIntervalSince(observed.observedAt) < 10 else { throw RemoteHTTPError(409, "최신 터미널 화면을 받지 못했습니다. VS Code 연결을 확인해주세요.") }
            raw = observed.raw; generation = observed.generation; observedAt = observed.observedAt
            appearance = observed.appearance; cursor = observed.cursor
            display = observed.display
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
        let presented = display?.screen ?? raw
        // A cached observation carries the same timestamp and immutable source
        // text. Reuse the prior projections without rescanning the full screen.
        let sameSourceText = ScreenTextEquality.identical(previous?.raw, raw)
        let sameObservation = display == nil && capture == nil && previous?.usesRawPresentation == true &&
            previous?.generation == generation && previous?.frame.observedAt == observedAt && sameSourceText
        // A repeated oversized frame already owns the exact truncated view.
        // Reusing it avoids walking and copying 160k graphemes on every browser
        // poll; native display text still takes the normal path because it may
        // change independently of the underlying terminal frame.
        let usesRawPresentation = display == nil
        let reusableScreen = usesRawPresentation && previous?.usesRawPresentation == true &&
            previous?.generation == generation && sameSourceText
        let screen: String
        if reusableScreen, let previous { screen = previous.frame.screen }
        else {
            // Byte/code-unit counts bound Character count without walking short
            // foreign strings by grapheme. Larger inputs keep the exact old suffix.
            let units = presented.isContiguousUTF8 ? presented.utf8.count : presented.utf16.count
            if units <= 160_000 {
                // Foundation bridge strings can traverse their NSString-backed
                // storage again on every JSON encode. The screen is already
                // captured as an immutable revision, so copy that text once to
                // native UTF-8 storage before retaining it in the frame cache.
                screen = presented.isContiguousUTF8 ? presented : String(decoding: presented.utf8, as: UTF8.self)
            } else { screen = String(presented.suffix(160_000)) }
        }
        let visibleAppearance = ScreenTextEquality.identical(screen, raw) ? appearance : nil
        let visibleCursor = ScreenTextEquality.identical(screen, presented) ? (display?.cursor ?? cursor)?.validated(for: screen) : nil
        let sameSource = sameObservation || sameSourceText && ScreenTextEquality.identical(previous?.frame.screen, screen)
        let token = sameSource && previous?.generation == generation && previous?.frame.appearance == visibleAppearance && previous?.frame.cursor == visibleCursor && previous?.frame.nativeDisplay == nativeDisplay && previous?.frame.outputReason == outputReason ? previous!.frame.revision : UUID().uuidString
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
        remoteFrameSequence += 1
        var frame = RemoteTerminalFrame(sessionID: sessionID, screen: screen, revision: token,
            observedAt: observedAt, keys: keys, inputReason: sourceReason ?? remoteInputReason(current), appearance: visibleAppearance,
            cursor: visibleCursor, streamID: relaySupported ? remoteStreams[sessionID]?.token : nil, nativeDisplay: nativeDisplay, outputReason: outputReason, sequence: remoteFrameSequence)
        // The last frame already retains this raw screen. Reuse only immutable
        // detection, including a negative result; replies and input checks stay live.
        frame.question = previous?.agent == current.agent && sameSourceText
            ? previous?.frame.question : TerminalChoiceQuestion.detect(raw, agent: current.agent)
        if var question = frame.question {
            question.reply = savedReply("terminalChoice:\(sessionID):\(question.id)")
            frame.question = question
        }
        remoteFrames[sessionID] = (frame, raw, generation, usesRawPresentation, orcaBinding, nativeOnly ? nativeBinding : nil, current.agent)
        frameSucceeded = true
        return frame
    }

    /// Scrollback never enters screen analysis, approval receipts or input revisions.
    public func remoteTerminalHistory(sessionID:String,snapshot:String?=nil,page:Int?=nil,refresh:Bool=false) async throws -> TerminalHistoryPage {
        guard !remoteInputStopped,let session=sessions[sessionID],session.phase != .ended,session.terminal == .terminal,
              remoteCanRead(session),let history=screenAdapters[.terminal]?.history else {
            throw RemoteHTTPError(409,"이 세션의 전체 기록을 읽을 수 없습니다. Mac 기본 Terminal 연결을 확인해주세요.")
        }
        if let capture=nativeWindowCapture(for:session),try await !capture.checkAutomationPermission() {throw TerminalAdapterError.permissionDenied}
        let reader=singleProcessReader,pid=session.pid,started=session.started,tty=session.tty,agent=session.agent
        let verify:@Sendable () throws -> Bool = {try reader(pid).contains {$0.pid==pid && $0.started==started && "/dev/"+$0.tty==tty && $0.agent==agent}}
        guard try await Task.detached(operation:verify).value else {throw RemoteHTTPError(409,"원래 CLI의 실행 정보가 바뀌었습니다. 목록을 새로고침해주세요.")}
        let target=ScreenTarget(tty:tty,sourcePID:pid,sourceStarted:started)
        let source=sessionID+"\n"+String(pid)+"\n"+started+"\n"+tty+"\n"+session.channel.rawValue
        if terminalHistoryStore==nil {terminalHistoryStore=TerminalHistoryStore(directory:paths.directory.appendingPathComponent("terminal-history-cache",isDirectory:true))}
        let result=try await terminalHistoryStore!.page(sessionID:sessionID,source:source,snapshot:snapshot,page:page,refresh:refresh,capture:{
            guard try verify() else {throw RemoteHTTPError(409,"원래 CLI가 바뀌어 기록을 읽지 않았습니다.")}
            let text=try history(target)
            guard try verify() else {throw RemoteHTTPError(409,"기록을 읽는 동안 원래 CLI가 바뀌었습니다.")}
            return text
        })
        guard !remoteInputStopped,let current=sessions[sessionID],current.phase != .ended,current.pid==pid,current.started==started,
              current.tty==tty,current.channel==session.channel,remoteCanRead(current) else {throw RemoteHTTPError(409,"기록을 읽는 동안 세션 연결이 바뀌었습니다.")}
        return result
    }

    public func remoteInput(_ object: JSONObject) async throws -> JSONObject {
        if let id=object["sessionID"] as? String {cancelCodexProgressCheck(id)}
        if let id = object["sessionID"] as? String, let pending = modelRetentionTasks[id] {
            manuallyChangedModelQuestions[id] = pending.generation + ":" + pending.questionID
            cancelModelRetention(id)
        }
        return try await remoteInput(object, automaticAuthorization: nil)
    }

    private func remoteInput(_ object: JSONObject, automaticAuthorization: (@MainActor () throws -> Void)?, authorizationSource: String = "현재 모델 자동 유지", codexStatusQuery: Bool = false, backgroundOnly: Bool = false) async throws -> JSONObject {
        var deliveryStarted = false
        do { return try await performRemoteInput(object, deliveryStarted: &deliveryStarted, automaticAuthorization: automaticAuthorization, authorizationSource: authorizationSource, codexStatusQuery: codexStatusQuery, backgroundOnly: backgroundOnly) }
        catch {
            var diagnostics = (error as? RemoteHTTPError)?.diagnostics ?? [:]
            if diagnostics["delivery"] == nil { diagnostics["delivery"] = deliveryStarted ? "unknown" : "not_started" }
            throw RemoteHTTPError((error as? RemoteHTTPError)?.status ?? 409, error.localizedDescription, diagnostics: diagnostics)
        }
    }

    private func performRemoteInput(_ object: JSONObject, deliveryStarted: inout Bool, automaticAuthorization: (@MainActor () throws -> Void)?, authorizationSource: String = "현재 모델 자동 유지", codexStatusQuery: Bool = false, backgroundOnly: Bool = false) async throws -> JSONObject {
        try automaticAuthorization?()
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
        // This capability is private; callers cannot enable it through JSON. It
        // permits only the read-only slash command in a visibly empty Codex composer.
        if codexStatusQuery {
            guard [.message, .submit].contains(kind), ["/status", "/pwd"].contains(input.text),
                  codexGroupStatusEligible(session), CodexStatusIdentity.canQuery(observed.raw) else {
                throw RemoteHTTPError(409, "Codex 입력 상태가 바뀌어 세션 ID 조회를 보류했습니다.")
            }
        }
        if kind == .message {
            guard relay, codexStatusQuery || !session.pendingInTerminal, session.phase != .approval, !RemoteMessageReadiness.hasMenu(observed.raw, agent: session.agent),
                  [.terminal, .tmux].contains(session.terminal) else {
                throw RemoteHTTPError(409, "현재 원본 터미널의 질문에 먼저 답변해주세요.")
            }
        }
        if kind == .choice {
            let delegated = delegatedPermissionInputs.contains(id)
            guard let currentQuestion = delegated ? TerminalChoiceQuestion.detectPermission(observed.raw, agent: session.agent)
                                                  : TerminalChoiceQuestion.detect(observed.raw, agent: session.agent),
                  let questionID = object["questionID"] as? String, questionID == currentQuestion.id,
                  replyingQuestions.contains("terminalChoice:\(id):\(questionID)"),
                  let target = currentQuestion.targetIndex(command: input.text), currentQuestion.options.indices.contains(target),
                  currentQuestion.command(for: target) == input.text else {
                throw RemoteHTTPError(409, "질문이나 선택지가 바뀌어 답변하지 않았습니다. 현재 질문을 확인해주세요.")
            }
        }
        remoteInputSessions.insert(id)
        remoteTerminalChanges[id]?.notify()
        defer {
            remoteInputSessions.remove(id); remoteInputUntil[id] = Date().addingTimeInterval(0.8)
            invalidateRemoteRead(id)
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 810_000_000)
                guard let self, !self.remoteInputStopped, !self.userInputHasPriority(id) else { return }
                self.scheduleSystemSafety(id); self.scheduleScreenApproval(id); self.scheduleCapacityResume(id)
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
        } else if session.terminal == .terminal, input.isRelay, ![.message,.choice].contains(kind) {
            let single = singleProcessReader
            currentRecords = try await Task.detached { try single(session.pid) }.value
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
              kind != .message || (codexStatusQuery ? codexGroupStatusEligible(current) : !current.pendingInTerminal && current.phase != .approval),
              !orcaInput || remoteOrcaBindings[id]?.binding == observed.orcaBinding && remoteFrames[id]?.orcaBinding == observed.orcaBinding,
              (relay ? remoteStreams[id]?.token == (object["streamID"] as? String) : remoteFrames[id]?.frame.revision == token) else { throw RemoteHTTPError(409, "대상 CLI나 화면 상태가 바뀌었습니다. 최신 화면을 확인해주세요.") }
        if session.terminal == .terminal, relay || ![.text, .submit, .enter].contains(kind) {
            guard let original = remoteStreams[id]?.identity, let source = terminalInputIdentity(session.pid),
                  source.sameProcess(as: original), source.foregroundGroup == source.processGroup else {
                throw RemoteHTTPError(409, "원래 CLI의 실행 시각, TTY 또는 입력 대상이 바뀌어 입력하지 않았습니다.")
            }
        }
        // Pause, opt-out and a replaced model question can cancel during the
        // asynchronous process check. Web callers cannot supply this callback.
        try automaticAuthorization?()
        if codexStatusQuery {
            guard !(await nativeUserInputHasPriority(id,backgroundOnly:backgroundOnly)), !snapshot.paused, !automaticInputBusy(id),
                  codexGroupStatusEligible(current) else {
                throw RemoteHTTPError(409, "Codex 입력 상태가 바뀌어 세션 ID 조회를 보류했습니다.")
            }
        }
        // Reserve this exact frame before writing. Neither a timeout nor a second click replays it.
        if !relay { remoteFrames.removeValue(forKey: id) }
        invalidateRemoteRead(id)
        let textual = [.text, .submit, .message, .characters].contains(kind)
        var event = AuditEvent(sessionID: id, summary: textual ? String(input.text.prefix(200)) : kind.rawValue,
            outcome: "웹 입력 전달 확인 중", source: "같은 네트워크 웹", context: AuditContext(session: session), request: kind.rawValue, answer: textual ? input.text : kind.rawValue)
        if automaticAuthorization != nil { event.source = authorizationSource }
        if codexStatusQuery { event.source = "Codex 세션 ID 조회" }
        if kind == .choice, let question = TerminalChoiceQuestion.detect(observed.raw, agent: session.agent), let selected = question.targetIndex(command: input.text) {
            event.summary = question.question; event.request = question.question + "\n" + question.options.joined(separator: "\n"); event.answer = question.options[selected]
        }
        guard log(event) else { throw RemoteHTTPError(409, "입력 내역을 저장하지 못해 전송하지 않았습니다.") }
        do {
            deliveryStarted = true
            let sent: Bool
            if let host = ScreenHost(kind: session.terminal), let adapter = screenAdapters[host] {
                let job = currentRecords.filter { $0.tty == tty && $0.processGroup == process.processGroup }.map(\.pid)
                let target = ScreenTarget(tty: session.tty, handle: session.screenHandle, jobPIDs: job,
                    sourcePID: session.pid, sourceStarted: session.started, sourceIdentity: remoteStreams[id]?.identity)
                let write: @Sendable (ScreenTarget, String, AgentKind, RemoteTerminalInput) throws -> TerminalDelivery
                if backgroundOnly, host == .terminal {
                    guard let background = adapter.backgroundInput else {
                        throw RemoteHTTPError(409, "포커스 없는 터미널 전달을 사용할 수 없습니다.", diagnostics: ["delivery": "not_started"])
                    }
                    write = background
                } else { write = adapter.input }
                // Raw terminal adapters must send a paste event followed by
                // Enter. Codex can treat Enter in a burst of plain keys as
                // part of the paste and leave /status in the composer.
                let adapterInput = codexStatusQuery && kind == .submit && host != .terminal
                    ? RemoteTerminalInput(kind: .message, text: input.text)
                    : input
                let result = try await Task.detached { try write(target, observed.raw, session.agent, adapterInput) }.value
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
            guard sent else { throw RemoteHTTPError(409, "현재 화면이나 CLI가 바뀌어 입력하지 않았습니다. 최신 화면을 확인해주세요.", diagnostics: ["delivery": "not_started", "retryable": "true"]) }
            return ["sent": true, "message": "터미널에 입력을 전달했습니다. 화면에서 반영 결과를 확인하세요."]
        } catch {
            if event.outcome == "웹 입력 전달 확인 중" { event.outcome = "웹 입력 결과 미확인"; _ = log(event) }
            throw error
        }
    }

    private func automaticInputBusy(_ id: String) -> Bool {
        automaticInputSessions.contains(id) || osPermissionActing != nil || systemSafetyTasks[id] != nil || capacityStates[id]?.phase == .sending || pendingActions.values.contains { $0.sessionID == id }
    }

    private func sendOriginalTerminalMessage(_ original: AgentSession, object: JSONObject,
                                            codexStatusQuery: Bool = false, textOnly: Bool = false, backgroundOnly: Bool = false,
                                            preflight: ((RemoteTerminalFrame) async throws -> Void)? = nil) async throws -> JSONObject {
        var outcome = "not_started"
        do {
            guard original.agent != .shell, let text = object["text"] as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !text.contains("\0"),
                  let suppliedRevision = object["revision"] as? String, !suppliedRevision.isEmpty else {
                throw RemoteHTTPError(400, "메시지와 원본 터미널 연결을 확인해주세요.")
            }
            guard !sendingMessages.contains(original.id), !remoteInputStopped else { throw RemoteHTTPError(409, "메시지를 전달하고 있습니다. 잠시 후 다시 확인해주세요.") }
            sendingMessages.insert(original.id); defer { sendingMessages.remove(original.id) }
            for attempt in 0..<3 {
                let frame = try await remoteTerminal(sessionID: original.id, realtime: true, textOnly: textOnly)
                guard let current = sessions[original.id], current.pid == original.pid, current.started == original.started,
                      current.tty == original.tty, current.terminal == original.terminal,
                      current.bridgeID == original.bridgeID, current.terminalID == original.terminalID,
                      (codexStatusQuery ? codexGroupStatusEligible(current) : !current.pendingInTerminal && current.phase != .approval), frame.inputReason == nil,
                      !RemoteMessageReadiness.hasMenu(frame.screen, agent: current.agent) else {
                    throw RemoteHTTPError(409, "원본 터미널의 연결이나 질문 상태가 바뀌었습니다. 현재 화면을 확인해주세요.")
                }
                if let supplied = object["streamID"] as? String, supplied != frame.streamID {
                    throw RemoteHTTPError(409, "원본 터미널 연결이 바뀌었습니다. 같은 세션을 다시 연결해주세요.")
                }
                var input: JSONObject = ["sessionID": original.id, "revision": frame.revision, "text": text]
                var submitSeparately = false
                if codexStatusQuery, frame.keys.contains("submit") {
                    // Status queries require the exact empty-composer frame at dispatch.
                    input["kind"] = "submit"
                } else if frame.keys.contains("message"), let stream = frame.streamID {
                    input["kind"] = "message"; input["relay"] = true; input["streamID"] = stream
                } else if frame.keys.contains("submit") { input["kind"] = "submit" }
                else if frame.keys.contains("characters"), frame.keys.contains("enter"), let stream = frame.streamID {
                    guard !text.contains("\n"), !text.contains("\r") else { throw RemoteHTTPError(400, "이 원본 연결에는 한 줄 메시지를 입력해주세요. 작성한 내용은 보관합니다.") }
                    input["kind"] = "characters"; input["relay"] = true; input["streamID"] = stream; submitSeparately = true
                }
                else { throw RemoteHTTPError(409, "이 원본의 메시지 전송 연결을 확인해주세요. 작성한 내용은 보관합니다.") }
                var textWasSent = false
                do {
                    try await preflight?(frame)
                    if codexStatusQuery, !submitSeparately {
                        _ = try await remoteInput(input, automaticAuthorization: nil, codexStatusQuery: true, backgroundOnly: backgroundOnly)
                    } else if backgroundOnly {
                        _ = try await remoteInput(input, automaticAuthorization: nil, backgroundOnly: true)
                    } else { _ = try await remoteInput(input) }
                    if submitSeparately {
                        textWasSent = true; outcome = "unknown"
                        let next = try await remoteTerminal(sessionID: original.id, realtime: true, textOnly: textOnly)
                        guard next.streamID == frame.streamID, next.inputReason == nil,
                              !RemoteMessageReadiness.hasMenu(next.screen, agent: original.agent),
                              let current = sessions[original.id],
                              (codexStatusQuery ? codexGroupStatusEligible(current) : !current.pendingInTerminal && current.phase != .approval) else {
                            throw RemoteHTTPError(409, "문자는 전달했지만 원본의 입력 상태가 바뀌어 Enter를 보내지 않았습니다. 원본 화면을 확인해주세요.")
                        }
                        if codexStatusQuery {
                            guard !(await nativeUserInputHasPriority(original.id,backgroundOnly:backgroundOnly)), !snapshot.paused,
                                  PromptDetector.normalizedLines(next.screen).last(where: { $0.hasPrefix("›") || $0.hasPrefix("»") })?.dropFirst().trimmingCharacters(in: .whitespaces) == text else {
                                throw RemoteHTTPError(409, "Codex 조회 명령의 입력을 확인하지 못해 Enter를 보내지 않았습니다.")
                            }
                        }
                        let enter: JSONObject = ["sessionID": original.id, "revision": next.revision, "streamID": next.streamID!, "relay": true, "kind": "enter"]
                        if backgroundOnly { _ = try await remoteInput(enter, automaticAuthorization: nil, backgroundOnly: true) }
                        else { _ = try await remoteInput(enter) }
                    }
                    return ["ok": true, "transport": "terminal", "message": "같은 원본 터미널에 메시지를 전달했습니다."]
                } catch let error as RemoteHTTPError {
                    if textWasSent {
                        var diagnostics = error.diagnostics ?? [:]; diagnostics["delivery"] = "unknown"
                        throw RemoteHTTPError(error.status, error.localizedDescription, diagnostics: diagnostics)
                    }
                    outcome = error.diagnostics?["delivery"] ?? "unknown"
                    if outcome == "not_started", error.diagnostics?["retryable"] == "true", attempt < 2 { continue }
                    throw error
                }
            }
            throw RemoteHTTPError(409, "최신 원본 화면을 확인하고 다시 보내주세요.")
        } catch {
            var diagnostics = (error as? RemoteHTTPError)?.diagnostics ?? [:]
            if diagnostics["delivery"] == nil { diagnostics["delivery"] = outcome }
            throw RemoteHTTPError((error as? RemoteHTTPError)?.status ?? 409, error.localizedDescription, diagnostics: diagnostics)
        }
    }
    private func remoteUserInputHasPriority(_ id: String) -> Bool {
        remoteInputSessions.contains(id) || remoteInputUntil[id].map { Date() < $0 } == true
    }
    private func nativeUserInputHasPriority(_ id:String) -> Bool {
        sessions[id].map {nativeKeyboardActivity.hasPriority(terminal:$0.terminal) || testScreens.remoteControl.hasInputPriority(terminal:$0.terminal)} ?? false
    }
    private func nativeUserInputHasPriority(_ id:String,backgroundOnly:Bool) async -> Bool {
        guard backgroundOnly,let session=sessions[id] else {return nativeUserInputHasPriority(id)}
        if testScreens.remoteControl.hasInputPriority(terminal:session.terminal) {return true}
        let keyboard=nativeKeyboardActivity
        return await Task.detached(priority:.userInitiated) {keyboard.hasPriority(terminal:session.terminal,tty:session.tty)}.value
    }
    private func userInputHasPriority(_ id:String) -> Bool {
        codexAccountInputHeld(id) || changingGoals.contains(id) || remoteUserInputHasPriority(id) || nativeUserInputHasPriority(id)
    }
    private func userInputHasPriority(_ id:String,backgroundOnly:Bool) async -> Bool {
        if codexAccountInputHeld(id) || changingGoals.contains(id) || remoteUserInputHasPriority(id) {return true}
        let native=await nativeUserInputHasPriority(id,backgroundOnly:backgroundOnly)
        return native || codexAccountInputHeld(id) || changingGoals.contains(id) || remoteUserInputHasPriority(id)
    }
    func remoteTerminalObservation(sessionID: String) -> RemoteTerminalObservation {
        if remoteTerminalChanges[sessionID] == nil { remoteTerminalChanges[sessionID] = RemoteTerminalChangeSignal() }
        let observation = remoteTerminalChanges[sessionID]!.observe()
        if let host = sessions[sessionID].flatMap({ ScreenHost(kind: $0.terminal) }) {
            unchangedScreenReads[host] = 0
            screenPollSignals[host]?.notify()
        }
        if sessions[sessionID]?.terminal == .terminal {
            observation.observeNativeCursor { [weak self] in
                Task { @MainActor [weak self] in self?.invalidateRemoteRead(sessionID) }
            }
        }
        return observation
    }
    func remoteTerminalNeedsResponsiveRead(_ id: String) -> Bool {
        // New screen contents arrive through the host's change signal. Force
        // short confirmation reads only while a user or approval input is in
        // flight, not merely because the CLI is doing work in the background.
        remoteUserInputHasPriority(id) || automaticInputBusy(id)
    }

    private struct GroupStatusIdentity {
        let session: AgentSession
        let conversationID: String
        let home: String?
        var contradictedRollout: UUID? = nil
        var terminalName: String? = nil
    }
    private var groupStatusIdentities: [String: GroupStatusIdentity] = [:]
    private struct GroupMCPIdentity {
        let runtimeID: String
        let tty: String
        let cwd: String
        let home: String
        let conversationID: UUID?
        let observedAt: TimeInterval
    }
    private struct AgyState {
        let conversationId: String
        let isIdle: Bool
        let modelName: String?
    }
    private var agyEvents: [String: AgyState] = [:]

    private func applyAgyState(_ event: AgyState, to session: inout AgentSession) {
        session.channel = .hook
        session.providerID = event.conversationId
        session.setPhase(event.isIdle ? .idle : .working,
                         detail: event.isIdle ? "agy 입력 대기" : "agy 작업 중")
    }

    private var groupMCPIdentities: [String: GroupMCPIdentity] = [:]
    private static let groupMCPIdentityLifetime: TimeInterval = 120
    private static let missingCodexGroupIdentity = "로컬 대화 기록과 MCP 호출 정보로 이 터미널의 ID를 확인할 수 없습니다. 세션 ID 갱신을 실행하면 원래 탭의 새 /status 응답을 확인합니다."

    private func observeGroupMCPIdentity(_ object: JSONObject, owner: String) {
        guard object["agentKind"] as? String == AgentKind.codex.rawValue,
              object["codexCallerSource"] as? String == "codex_mcp_metadata",
              let id = (object["codexCallerConversationID"] as? String).flatMap(UUID.init(uuidString:)),
              (object["conversationID"] as? String).flatMap(UUID.init(uuidString:)) == id,
              let runtime = object["codexCallerRuntimeID"] as? String, let session = sessions[runtime],
              session.agent == .codex, session.phase != .ended,
              let home = object["codexCallerHome"] as? String, home.hasPrefix("/"),
              !home.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        groupMCPIdentities = groupMCPIdentities.filter { now - $0.value.observedAt < Self.groupMCPIdentityLifetime }
        guard groupMCPIdentities[owner] != nil || groupMCPIdentities.count < 1024 else { return }
        let previous = groupMCPIdentities[owner]
        // The same helper can see multiple conversations. Retain the conflict
        // until it expires or the bound terminal starts a new conversation.
        let conflict = previous.map { $0.runtimeID == runtime && $0.tty == session.tty && $0.cwd == session.cwd &&
            $0.home == home && $0.conversationID != id } == true
        let observedAt = conflict ? previous?.observedAt ?? now : now
        groupMCPIdentities[owner] = GroupMCPIdentity(runtimeID: runtime, tty: session.tty, cwd: session.cwd,
                                                    home: home, conversationID: conflict ? nil : id, observedAt: observedAt)
    }

    private func groupMCPIdentity(for session: AgentSession, home: String?) -> GroupMCPIdentity? {
        let now = ProcessInfo.processInfo.systemUptime
        let candidates = groupMCPIdentities.values.filter {
            $0.runtimeID == session.id && $0.tty == session.tty && $0.cwd == session.cwd &&
                (home == nil || $0.home == home) && now - $0.observedAt < Self.groupMCPIdentityLifetime
        }
        guard let match = candidates.first, let id = match.conversationID,
              candidates.allSatisfy({ $0.home == match.home && $0.conversationID == id }) else { return nil }
        return match
    }

    private func discardGroupMCPIdentities(for runtime: String) {
        groupMCPIdentities = groupMCPIdentities.filter { $0.value.runtimeID != runtime }
    }
    private var groupIdentityObservationTask: Task<[SessionGroupLiveSession], Error>?
    private var groupStatusQueries: Set<String> = []
    private var groupClearOperations: [SessionGroupClearOperation]?
    private var groupClearTask: Task<Void, Never>?
    private var groupClearDiscoveryReady = false
    private var tabLabelChanges: Set<String> = []
    public var groupClearInterval: TimeInterval = 2
    private var profileGroupAttachments:[TerminalProfileGroupAttachment]=[]

    public func terminalProfileGroups(candidates:[TerminalProfileCandidate]) throws -> [TerminalProfileGroup] {
        TerminalProfileGroup.capture(try SessionGroupStore(directory:paths.directory).load(),candidates:candidates)
    }

    public func restoreTerminalProfileGroups(_ profile:TerminalSessionProfile,results:[TerminalProfileRestoreResult],
                                            previous:[TerminalProfileCandidate]) async throws {
        let profile=try profile.validated(),store=SessionGroupStore(directory:paths.directory),saved=try store.load()
        // Old files have no group snapshot. Recover only exact known conversations
        // from the still-persisted groups; never use a project/title guess.
        let snapshots=profile.groups ?? TerminalProfileGroup.capture(saved,candidates:profile.entries.map {.init(id:$0.id.uuidString,entry:$0)})
        let successful=results.filter {$0.phase == .opened || $0.phase == .alreadyOpen}
        var next=try TerminalProfileGroupRestore.merge(snapshots,into:saved,restored:Set(successful.map(\.id)))
        var pending:[TerminalProfileGroupAttachment]=[]
        for snapshot in snapshots {
            guard let gi=next.firstIndex(where:{$0.id==snapshot.group.id}) else{continue}
            for link in snapshot.links {
                guard let result=successful.first(where:{$0.id==link.entryID}),let entry=profile.entries.first(where:{$0.id==link.entryID}),
                      let mi=next[gi].members.firstIndex(where:{$0.id==link.memberID}) else{continue}
                let active=previous.filter {$0.entry.key==entry.key}
                if result.phase == .alreadyOpen,active.count==1,let original=active.first,
                   let current=sessions[original.id],current.phase != .ended,current.agent.rawValue==entry.agent,current.cwd==entry.cwd {
                    if next[gi].members[mi].runtimeID != current.id { next[gi].members[mi].tabShell = nil }
                    next[gi].members[mi].runtimeID=current.id
                } else if let tty=result.tty,TerminalProfileLauncher.validTTY(tty) {
                    pending.append(.init(groupID:snapshot.group.id,memberID:link.memberID,entry:entry,tty:tty,
                                         excludedRuntimes:Set(previous.map(\.id)),expires:Date().addingTimeInterval(120)))
                }
            }
        }
        if next != saved {try store.save(next,expected:saved)}
        for attachment in pending {
            profileGroupAttachments.removeAll {$0.groupID==attachment.groupID && $0.memberID==attachment.memberID}
            profileGroupAttachments.append(attachment)
        }
        _ = try await sessionGroupSessions()
        refreshSessionGroupBadges()
    }

    /// A recovery receipt is not a CLI question. The caller must still prove an
    /// empty composer from a fresh screen before sending exactly /status.
    private func codexGroupStatusEligible(_ session: AgentSession) -> Bool {
        guard session.agent == .codex, ![.ended, .approval].contains(session.phase) else { return false }
        if session.pendingInTerminal {
            return session.pendingRequestID?.hasPrefix("capacity:review:") == true
        }
        return true // Work can continue while /status reads the current session.
    }

    private func groupStatusBlockReason(_ session: AgentSession,includeNativeInput:Bool = true) -> (message: String, transient: Bool)? {
        let id = session.id
        if !codexGroupStatusEligible(session) { return ("터미널의 질문·승인 상태를 먼저 확인해주세요.", false) }
        if snapshot.paused || remoteInputStopped { return ("AutoApprove가 일시정지되어 세션 ID 조회를 보류했습니다.", false) }
        if codexAccountInputHeld(id) { return (codexApprovalHoldReason(sessionID: id) ?? Self.codexAccountHoldMessage, false) }
        if changingGoals.contains(id) { return ("이 세션의 Goal 설정을 변경하고 있어 ID 조회를 보류했습니다.", false) }
        if automaticInputBusy(id) { return ("자동 승인 또는 복구 입력을 전달하고 있어 ID 조회를 보류했습니다. 입력 완료 후 다시 갱신해주세요.", true) }
        if remoteUserInputHasPriority(id) { return ("이 세션에 전달 중인 입력의 보호 시간이 끝나지 않아 ID 조회를 보류했습니다.", true) }
        if includeNativeInput && nativeUserInputHasPriority(id) { return ("터미널 앱의 키보드·원격 조작 우선권이 유지되어 ID 조회를 보류했습니다. 입력과 보조키를 놓은 뒤 다시 갱신해주세요.", true) }
        return nil
    }
    private func groupStatusBlockReason(_ session:AgentSession,backgroundOnly:Bool) async -> (message:String,transient:Bool)? {
        guard backgroundOnly else {return groupStatusBlockReason(session)}
        if let reason=groupStatusBlockReason(session,includeNativeInput:false) {return reason}
        if await nativeUserInputHasPriority(session.id,backgroundOnly:true) {return ("대상 터미널의 키보드·원격 조작 우선권이 유지되어 ID 조회를 보류했습니다.",true)}
        return nil
    }

    /// Explicit queries may wait for a short input cooldown, but never bypass it.
    /// A new question, draft or process replacement is checked again at dispatch.
    private func waitForGroupStatusInput(_ original: AgentSession,backgroundOnly:Bool = false) async throws {
        let deadline = Date().addingTimeInterval(3)
        while true {
            try Task.checkCancellation()
            guard let current = sessions[original.id], current.pid == original.pid, current.started == original.started,
                  current.tty == original.tty, current.cwd == original.cwd, current.terminal == original.terminal,
                  current.phase != .ended else { throw AppError.message("원래 터미널 연결이 바뀌어 ID 조회를 보류했습니다.") }
            guard let reason = await groupStatusBlockReason(current,backgroundOnly:backgroundOnly) else { return }
            guard reason.transient, Date() < deadline else { throw AppError.message(reason.message) }
            try await Task.sleep(for: .milliseconds(200))
        }
    }

    /// Read the original tab without selecting it. A shared server can own every
    /// rollout in a folder, so its home or a running thread alone cannot bind a tab.
    private func groupNamedConversation(_ original: AgentSession) async -> (id: String, home: String, name: String)? {
        guard original.agent == .codex, let host = ScreenHost(kind: original.terminal),
              [.terminal, .iterm].contains(host), remoteCanRead(original),
              let adapter = screenAdapters[host] else { return nil }
        let target = ScreenTarget(tty: original.tty, handle: original.screenHandle,
                                  sourcePID: original.pid, sourceStarted: original.started)
        func readFrame() async -> TerminalScreen? {
            try? await Task.detached(priority: .utility) {
                let snapshot = try (adapter.identityScreens ?? adapter.screens)([target])
                guard snapshot.failures.isEmpty, snapshot.screens.count == 1,
                      snapshot.screens[0].tty == target.tty else { return nil as TerminalScreen? }
                return snapshot.screens[0]
            }.value
        }
        guard let first = await readFrame(), let title = CodexGroupNamedConversation.title(in: first, cwd: original.cwd),
              let name = CodexProfileConversationBinding.terminalName(title, cwd: original.cwd),
              var server = try? await questionTransport.queueHome(original) else { return nil }
        let home = server.home
        guard let id = await Task.detached(priority: .utility, operation: {
            CodexGroupNamedConversation.lookup(title: title, cwd: original.cwd, home: home)
        }).value else { return nil }
        func compatible(_ frame: TerminalScreen) -> Bool {
            let cards = CodexStatusIdentity.cards(frame.contents)
            return cards.isEmpty || Set(cards.keys) == [id.lowercased()]
        }
        server.threadID = id
        guard compatible(first), (try? await codexQueue.validate(server, original.cwd)) != nil,
              let last = await readFrame(), compatible(last),
              let lastTitle = CodexGroupNamedConversation.title(in: last, cwd: original.cwd),
              CodexProfileConversationBinding.terminalName(lastTitle, cwd: original.cwd) == name else { return nil }
        return (id, home, name)
    }

    /// Only an explicit refresh may query the original tab when passive evidence is missing.
    @discardableResult public func refreshSessionGroupMemberID(groupID: UUID, memberID: UUID, expectedGroup: SessionGroup? = nil, selectedReplacement: String? = nil, expectedConversationID: String? = nil) async throws -> SessionGroupIdentityRefresh {
        let store = SessionGroupStore(directory: paths.directory), saved = try store.load()
        if let expectedGroup, saved.first(where: { $0.id == groupID })?.sameMembership(as: expectedGroup) != true {
            throw RemoteHTTPError(409, "그룹 구성이 바뀌어 갱신하지 않았습니다. get_session_groups로 다시 확인해주세요.")
        }
        guard let group = saved.first(where: { $0.id == groupID }),
              let member = group.members.first(where: { $0.id == memberID }) else {
            throw AppError.message("갱신할 그룹 구성원을 찾지 못했습니다.")
        }
        guard !groupClearActive(groupID) else { throw AppError.message("이 그룹의 초기화가 끝난 뒤 ID를 갱신해주세요.") }
        // The original binding normally makes a targeted read sufficient. A
        // resumed conversation can use an exact UUID match elsewhere.
        let isCodex = member.agent == .codex
        var connection: SessionGroupLiveSession?
        if let runtime = member.runtimeID {
            let observed = try await readSessionGroupSessions(runtimeID: runtime, reconcile: false, useStatusCache: !isCodex)
            connection = SessionGroupMatching.connection(member, in: observed)
        }
        var replacing = false
        if connection == nil {
            let observed = try await readSessionGroupSessions(reconcile: false, useStatusCache: !isCodex)
            connection = SessionGroupMatching.match(member, in: observed)
            if connection == nil {
                connection = SessionGroupMatching.replacement(member, in: observed, selected: selectedReplacement)
                replacing = connection != nil
            }
        }
        if selectedReplacement != nil && !replacing { throw AppError.message("기존 연결 또는 선택한 대화가 바뀌었습니다. 목록을 다시 확인해주세요.") }
        guard let connection, let original = sessions[connection.id] else {
            throw AppError.message("원래 터미널 연결을 확인해주세요. 다시 실행한 세션은 실행 중인 세션에 연결한 뒤 갱신할 수 있습니다.")
        }
        let runtime = original.id
        let id: String
        var verifiedInTab = false
        var namedHome: String?
        var verifiedName: String?
        if let confirmed = connection.conversationID, UUID(uuidString: confirmed) != nil {
            id = confirmed
        } else if isCodex, !replacing, let named = await groupNamedConversation(original) {
            id = named.id
            namedHome = named.home
            verifiedName = named.name
            verifiedInTab = true
        } else {
            if original.agent == .agy { throw AppError.message("연결 설정에서 agy 훅을 설치하고 해당 대화의 다음 이벤트를 기다려주세요.") }
            if !isCodex && (original.phase != .idle || original.pendingInTerminal || automaticInputBusy(runtime) || userInputHasPriority(runtime)) {
                throw AppError.message("원래 터미널이 대기 중일 때 갱신할 수 있습니다. 작업·질문·승인 상태를 확인해주세요.")
            }
            // With a shared server the TUI owns neither the rollout nor the MCP helper.
            id = try await statusConversationID(original, backgroundOnly: isCodex, markRepeatedCard: isCodex)
            verifiedInTab = true
        }
        let verify = remoteProcessVerifier
        guard try await Task.detached(priority: .utility, operation: { try verify(original) }).value,
              let current = sessions[runtime], current.pid == original.pid, current.started == original.started,
              current.tty == original.tty, current.cwd == original.cwd, current.terminal == original.terminal,
              current.phase != .ended, !remoteInputStopped else {
            throw AppError.message("조회 중 원래 터미널 연결이 바뀌었습니다. 기존 ID를 유지합니다.")
        }
        if connection.codexIdentityFromMCP, groupMCPIdentity(for: current, home: connection.providerHome)?.conversationID != UUID(uuidString: id) {
            throw AppError.message("조회 중 대상 터미널의 MCP 호출 정보가 바뀌었습니다. 세션 ID를 다시 갱신해주세요.")
        }
        guard let uuid = UUID(uuidString: id) else { throw AppError.message("올바른 세션 ID를 확인하지 못했습니다.") }
        let home = namedHome ?? connection.providerHome ?? member.providerHome
        if isCodex, verifiedInTab {
            let live = try await readSessionGroupSessions(runtimeID: runtime, reconcile: false, useStatusCache: false)
            guard let observed = live.first(where: { $0.id == runtime }),
                  observed.conversationID.map({ UUID(uuidString: $0) == uuid }) ?? true,
                  !groupClearActive(groupID) else {
                throw AppError.message("조회 중 대상 탭의 대화가 바뀌었습니다. 세션 ID를 다시 갱신해주세요.")
            }
        }
        if replacing {
            if let expectedConversationID, UUID(uuidString: expectedConversationID) != uuid {
                throw AppError.message("선택한 뒤 대상 대화가 바뀌었습니다. 다시 선택해주세요.")
            }
            let all = try await readSessionGroupSessions(reconcile: false, useStatusCache: false)
            guard selectedReplacement != nil || !group.members.contains(where: { $0.id != memberID && $0.runtimeID != runtime && $0.tabShell == member.tabShell }),
                  let checked = SessionGroupMatching.replacement(member, in: all, selected: selectedReplacement),
                  checked.id == runtime, checked.tabShell == connection.tabShell, checked.providerHome == home,
                  checked.conversationID.map({UUID(uuidString: $0) == uuid}) ?? true,
                  !all.contains(where: { $0.id != runtime && $0.session.agent == .codex && $0.providerHome == home && $0.conversationID.flatMap(UUID.init(uuidString:)) == uuid }) else {
                throw AppError.message("교체할 터미널 또는 대화 ID가 바뀌었습니다.")
            }
        }
        var confirmedMember = member
        if replacing { confirmedMember.tabShell = connection.tabShell }
        confirmedMember.conversationID = uuid.uuidString.lowercased()
        confirmedMember.runtimeID = runtime
        confirmedMember.providerHome = home
        let latest = try store.load()
        guard let gi = latest.firstIndex(where: { $0.id == groupID }),
              let mi = latest[gi].members.firstIndex(where: { $0.id == memberID }),
              latest[gi].members[mi] == member || (isCodex && latest[gi].members[mi] == confirmedMember),
              !groupClearActive(groupID) else {
            throw AppError.message("조회 중 그룹 연결이 바뀌었습니다. 다시 조회해주세요.")
        }
        // Automatic reconciliation may have saved exactly this member while
        // the explicit refresh verified the process. Other edits still conflict.
        if expectedGroup != nil {
            var originalGroup = latest[gi]
            originalGroup.members[mi] = member
            guard originalGroup.sameMembership(as: group) else { throw AppError.message("조회 중 그룹 연결이 바뀌었습니다. 다시 조회해주세요.") }
        }
        let conflicts = latest[gi].members.filter { other in
            other.id != memberID && (other.runtimeID == runtime ||
                (other.agent == member.agent && other.providerHome == home && UUID(uuidString: other.conversationID) == uuid))
        }
        var next = latest
        next[gi].members[mi] = confirmedMember
        if !conflicts.isEmpty {
            guard replacing, latest[gi].sameMembership(as: group), conflicts.count == 1, let duplicate = conflicts.first,
                  duplicate.runtimeID == runtime, duplicate.agent == .codex, duplicate.providerHome == home,
                  UUID(uuidString: duplicate.conversationID) == uuid,
                  !group.isLeader(duplicate.id), group.children(of: duplicate.id).isEmpty,
                  duplicate.parentMemberID == nil || duplicate.parentMemberID == member.parentMemberID else {
                throw AppError.message("확인한 세션 ID가 이미 이 그룹의 다른 구성원에 연결되어 있습니다.")
            }
            let box = try groupMailbox()
            guard try box.list(groupID: groupID, memberID: duplicate.id, includeAcknowledged: true, limit: 1).isEmpty,
                  try box.list(groupID: groupID, memberID: duplicate.id, outbox: true, includeAcknowledged: true, limit: 1).isEmpty,
                  try !groupOrchestration().assignments.contains(where: { $0.groupID == groupID && ($0.workerMemberID == duplicate.id || $0.parentMemberID == duplicate.id) }) else {
                throw AppError.message("중복 구성원에 연결된 메시지나 작업 기록이 있어 병합을 보류했습니다.")
            }
            next[gi].members.removeAll { $0.id == duplicate.id }
        }
        if next != latest { try store.save(next, expected: latest) }
        if verifiedInTab {
            let rollout = connection.conversationID.flatMap(UUID.init(uuidString:))
            groupStatusIdentities[runtime] = GroupStatusIdentity(session: current, conversationID: id, home: home,
                                                               contradictedRollout: rollout == uuid ? nil : rollout, terminalName: verifiedName)
        } else if isCodex {
            groupStatusIdentities.removeValue(forKey: runtime)
        }
        refreshSessionGroupBadges()
        return SessionGroupIdentityRefresh(conversationID: uuid.uuidString.lowercased(), mergedMemberID: conflicts.first?.id, changed: UUID(uuidString: member.conversationID) != uuid)
    }

    /// A status card can extend above Terminal's visible frame. Capture only
    /// counts, on explicit refresh, without retaining or recording scrollback.
    private func groupStatusHistory<T: Sendable>(_ original: AgentSession, project: @escaping @Sendable (String) -> T) async throws -> T? {
        guard original.agent == .codex, original.terminal == .terminal,
              remoteCanRead(original), let history = screenAdapters[.terminal]?.history else { return nil }
        let verify = remoteProcessVerifier
        let target = ScreenTarget(tty: original.tty, handle: original.screenHandle,
                                  sourcePID: original.pid, sourceStarted: original.started)
        let proof = try await Task.detached(priority: .utility) {
            guard try verify(original) else { throw AppError.message("원래 터미널 연결이 바뀌었습니다.") }
            let text = try history(target)
            guard try verify(original) else { throw AppError.message("기록을 읽는 동안 터미널 연결이 바뀌었습니다.") }
            return project(String(text.suffix(160_000)))
        }.value
        try Task.checkCancellation()
        guard !remoteInputStopped, let current = sessions[original.id], current.pid == original.pid,
              current.started == original.started, current.tty == original.tty, current.cwd == original.cwd,
              current.terminal == original.terminal, current.phase != .ended, remoteCanRead(current) else {
            throw AppError.message("조회 중 원래 터미널 연결이 바뀌었습니다. 저장하지 않았습니다.")
        }
        return proof
    }

    /// Types /status into an empty composer and reads the fresh status card, including during Codex work.
    package func statusConversationID(_ original: AgentSession,backgroundOnly:Bool = false, markRepeatedCard: Bool = false,
                                      waitForInput: Bool = true) async throws -> String {
        if original.agent == .codex, waitForInput {try await waitForGroupStatusInput(original,backgroundOnly:backgroundOnly)}
        let runtime = original.id
        guard !sendingMessages.contains(runtime), groupStatusQueries.insert(runtime).inserted else {
            throw AppError.message("이미 이 터미널의 세션 ID를 조회하고 있습니다.")
        }
        defer { groupStatusQueries.remove(runtime) }
        let before = try await remoteTerminal(sessionID: runtime, realtime: true, textOnly: original.agent == .codex)
        let ready = original.agent == .codex ? CodexStatusIdentity.canQuery(before.screen) :
            SystemSafetyComposer.capture(before.screen, agent: original.agent, text: "/status") != nil &&
                PromptDetector.normalizedLines(before.screen).last(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("❯") })?.trimmingCharacters(in: .whitespaces) == "❯"
        guard ready else {
            let phase = ActivityDetector.detect(before.screen, agent: original.agent).phase
            let reason = phase == .working && original.agent != .codex ? "작업 중인 터미널에는 조회 명령을 추가하지 않습니다. 작업이 끝난 뒤 갱신해주세요." :
                phase == .input ? "터미널 입력창에 작성 중인 내용이 있습니다. 비운 뒤 다시 갱신해주세요." :
                "빈 입력창의 대기 상태를 확인하지 못했습니다. 질문·메뉴를 닫고 현재 터미널 화면을 확인해주세요."
            throw AppError.message(reason)
        }
        // In a bounded Terminal history, appending an identical card can evict
        // the previous one. Establish an observable boundary before dispatch.
        var hasDirectoryBoundary = false
        if markRepeatedCard, original.agent == .codex, original.terminal == .terminal {
            let hasPriorCard: Bool
            if !CodexStatusIdentity.cards(before.screen).isEmpty { hasPriorCard = true }
            else { hasPriorCard = (try? await groupStatusHistory(original) { !CodexStatusIdentity.cards($0).isEmpty }) == true }
            if hasPriorCard {
                _ = try await sendOriginalTerminalMessage(original, object: ["text": "/pwd", "revision": before.revision],
                    codexStatusQuery: true, textOnly: true, backgroundOnly: backgroundOnly)
                for _ in 0..<15 {
                    try await Task.sleep(for: .milliseconds(120))
                    let frame = try await remoteTerminal(sessionID: runtime, realtime: true, textOnly: true)
                    if CodexStatusIdentity.directoryBoundary(frame.screen, cwd: original.cwd) == .ready {
                        hasDirectoryBoundary = true
                        break
                    }
                }
                // The /pwd dispatch takes the normal input cooldown. Honor it
                // (and any user keystrokes) before composing the second command.
                try await waitForGroupStatusInput(original, backgroundOnly: backgroundOnly)
            }
        }
        var baseline = before.screen
        var historyBefore: CodexStatusIdentity?
        _ = try await sendOriginalTerminalMessage(original, object: ["text": "/status", "revision": before.revision], codexStatusQuery: original.agent == .codex, textOnly: original.agent == .codex, backgroundOnly:backgroundOnly, preflight: { frame in
            guard original.agent == .codex else { return }
            // Record the baseline for this send attempt. A prior /status can
            // finish while the new request is locating the original tab.
            baseline = frame.screen
            hasDirectoryBoundary = hasDirectoryBoundary && CodexStatusIdentity.directoryBoundary(frame.screen, cwd: original.cwd) == .ready
            let previous = try? await self.groupStatusHistory(original) { text in
                (CodexStatusIdentity(screen: text), CodexStatusIdentity.directoryBoundary(text, cwd: original.cwd))
            }
            hasDirectoryBoundary = hasDirectoryBoundary && previous?.1 == .ready
            historyBefore = previous?.0
            guard let current = self.sessions[runtime] else { throw RemoteHTTPError(409, "원래 터미널 연결이 바뀌었습니다.") }
            if let reason = await self.groupStatusBlockReason(current,backgroundOnly:backgroundOnly) { throw RemoteHTTPError(409, reason.message) }
        })
        sendingMessages.insert(runtime); defer { sendingMessages.remove(runtime) }
        let visibleBefore = original.agent == .codex ? CodexStatusIdentity(screen: baseline) : nil
        if let visibleBefore { historyBefore?.counts.merge(visibleBefore.counts, uniquingKeysWith: max) }
        for attempt in 0..<60 {
            try await Task.sleep(for: .milliseconds(200))
            guard let current = sessions[runtime], current.pid == original.pid, current.started == original.started,
                  current.cwd == original.cwd, current.tty == original.tty, current.phase != .ended else {
                throw AppError.message("조회 중 원래 터미널 연결이 바뀌었습니다. 저장하지 않았습니다.")
            }
            let frame = try await remoteTerminal(sessionID: runtime, realtime: true, textOnly: original.agent == .codex)
            if let visibleBefore {
                let visibleCards = CodexStatusIdentity.cards(frame.screen)
                // Moving an older card into the visible region is not a new
                // response. A result must exceed what was already present in
                // the original tab, including available scrollback.
                if let id = visibleBefore.freshThread(in: visibleCards),
                   visibleCards[id, default: 0] > (historyBefore?.counts[id] ?? 0) { return id }
            } else if let id = SessionGroupTerminalStatus.freshConversationID(before: baseline, after: frame.screen, agent: original.agent) { return id }
            // Never infer freshness from a UUID merely becoming visible after
            // scrolling. Both snapshots must show a newly appended full card.
            // At most three fallback reads per explicit query, never per poll.
            if [4, 29, 59].contains(attempt), let historyBefore,
               let after = try? await groupStatusHistory(original, project: { text in
                   (CodexStatusIdentity.cards(text), CodexStatusIdentity.directoryBoundary(text, cwd: original.cwd))
               }) {
                if hasDirectoryBoundary, case let .card(id) = after.1 { return id }
                if let id = historyBefore.freshThread(in: after.0) { return id }
            }
        }
        throw AppError.message("터미널의 /status 화면에서 세션 ID를 확인하지 못했습니다. 기존 ID를 유지합니다.")
    }

    /// Resolve only each already-discovered process. This never uses thread/list.
    public func sessionGroupSessions() async throws -> [SessionGroupLiveSession] {
        if let pending = groupIdentityObservationTask { return try await pending.value }
        let pending = Task { try await readSessionGroupSessions() }
        groupIdentityObservationTask = pending
        defer { groupIdentityObservationTask = nil }
        let observed = try await pending.value
        if !Task.isCancelled, !pending.isCancelled { groupConnectionObservation = (.now, observed) }
        return observed
    }

    private func readSessionGroupSessions(runtimeID: String? = nil, reconcile: Bool = true, useStatusCache: Bool = true) async throws -> [SessionGroupLiveSession] {
        let candidates = runtimeID.map { sessions[$0].map { [$0] } ?? [] } ?? Array(sessions.values)
        let originals = candidates.filter { $0.agent != .shell && $0.phase != .ended && $0.pid > 0 }
        guard !originals.isEmpty || runtimeID == nil else { return [] }
        guard originals.count <= 512 else { throw AppError.message("세션이 너무 많아 그룹 구성을 확인하지 못했습니다.") }
        let readAll = processReader, readOne = singleProcessReader, pid = runtimeID == nil ? nil : originals.first?.pid
        let reader: @Sendable () throws -> [ProcessRecord] = { if let pid { return try readOne(pid) }; return try readAll() }
        let registry = claudeRegistryReader, codexReader = codexGroupReader, codexEnvironment = codexGroupEnvironment
        let records = try await Task.detached(priority: .utility) { try reader() }.value
        var result: [SessionGroupLiveSession] = []
        for original in originals {
            try Task.checkCancellation()
            guard let record = records.first(where: { $0.key == original.id && $0.agent == original.agent && "/dev/" + $0.tty == original.tty }) else { continue }
            let environment = await Task.detached(priority: .utility) {
                original.agent == .codex ? codexEnvironment(record) : (original.agent == .claude ? ProcessEnvironment.read(record) : nil)
            }.value
            var home: String?, conversation: String?, messagingName: String?, claudeStatus: String?
            if original.agent == .codex {
                home = CodexGroupIdentity.home(environment: environment)
                let location = try? await Task.detached(priority: .utility) {
                    try codexReader(record)
                }.value
                if let location, UUID(uuidString: location.threadID) != nil {
                    conversation = location.threadID
                    home = URL(fileURLWithPath: location.database).deletingLastPathComponent().resolvingSymlinksInPath().path
                }
            } else if original.agent == .agy {
                home = AgyHookInstaller.file.deletingLastPathComponent().path
                conversation = agyEvents[original.id]?.conversationId
            } else {
                if let environment {
                    let path = environment["CLAUDE_CONFIG_DIR"] ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude").path
                    home = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
                    let directory = URL(fileURLWithPath: path)
                    let rows = await Task.detached(priority: .utility) { ClaudeSessionRegistry.read(records: [record], directory: directory) }.value
                    let ids = Set(rows.filter { $0.processID == original.id }.compactMap(\.conversationID))
                    if ids.count == 1, let id = ids.first, UUID(uuidString: id) != nil { conversation = id }
                    let matching = rows.filter { $0.processID == original.id && $0.conversationID == conversation }
                    if conversation != nil, matching.count == 1 {
                        messagingName = matching[0].peerName
                        claudeStatus = matching[0].status
                    }
                } else {
                    // Injected registry readers are also useful for isolated tests; do not infer a home.
                    let rows = await Task.detached(priority: .utility) { registry([record]) }.value
                    let ids = Set(rows.filter { $0.processID == original.id }.compactMap(\.conversationID))
                    if ids.count == 1, let id = ids.first, UUID(uuidString: id) != nil { conversation = id }
                    let matching = rows.filter { $0.processID == original.id && $0.conversationID == conversation }
                    if conversation != nil, matching.count == 1 {
                        messagingName = matching[0].peerName
                        claudeStatus = matching[0].status
                    }
                }
            }
            guard let current = sessions[original.id], current.pid == original.pid, current.started == original.started,
                  current.tty == original.tty, current.agent == original.agent, current.cwd == original.cwd,
                  current.codexApprovalBinding?.threadID == original.codexApprovalBinding?.threadID,
                  current.phase != .ended else { continue }
            var observation = SessionGroupLiveSession(session: current, conversationID: conversation, providerHome: home, messagingName: messagingName)
            observation.claudeRegisteredStatus = claudeStatus
            result.append(observation)
        }
        // Discovery can lag while a process exits or a PID is reused. Re-read
        // the process list after the async work, and never publish a stale match.
        let latest = try await Task.detached(priority: .utility) { try reader() }.value
        let byPID = Dictionary(latest.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        let observed = result.compactMap { observation -> SessionGroupLiveSession? in
            guard let current = sessions[observation.id], current.phase != .ended,
                  current.pid == observation.session.pid, current.started == observation.session.started,
                  current.tty == observation.session.tty, current.cwd == observation.session.cwd,
                  current.agent == observation.session.agent,
                  current.codexApprovalBinding?.threadID == observation.session.codexApprovalBinding?.threadID,
                  latest.contains(where: { $0.key == observation.id && $0.agent == current.agent && "/dev/" + $0.tty == current.tty }) else { return nil }
            var result = observation
            result.session = current
            if current.agent == .agy { result.conversationID = agyEvents[current.id]?.conversationId }
            if let process = byPID[current.pid] { result.tabShell = SessionGroupTabShell.observe(current, process: process, records: byPID) }
            let mcp = current.agent == .codex ? groupMCPIdentity(for: current, home: result.providerHome) : nil
            if let mcp, let id = mcp.conversationID {
                groupStatusIdentities.removeValue(forKey: current.id)
                if result.conversationID == nil {
                    result.conversationID = id.uuidString.lowercased()
                    result.providerHome = mcp.home
                    result.codexIdentityFromMCP = true
                }
            } else if useStatusCache, let status = groupStatusIdentities[current.id] {
                let compatible = status.session.started == current.started && status.session.tty == current.tty &&
                    status.session.cwd == current.cwd && status.session.agent == current.agent &&
                    (result.providerHome == nil || status.home == nil || result.providerHome == status.home)
                let observedID = result.conversationID.flatMap(UUID.init(uuidString:))
                let nameChanged = status.terminalName.map { name in
                    current.terminalTitle != status.session.terminalTitle &&
                        CodexProfileConversationBinding.terminalName(current.terminalTitle, cwd: current.cwd) != name
                } ?? false
                if compatible && !nameChanged && (observedID == nil || observedID == status.contradictedRollout) {
                    result.conversationID = status.conversationID
                    result.providerHome = result.providerHome ?? status.home
                } else if nameChanged || !compatible || observedID != UUID(uuidString: status.conversationID) {
                    groupStatusIdentities.removeValue(forKey: current.id)
                }
            }
            return result
        }.sorted { $0.session.displayedTerminalTitle.localizedStandardCompare($1.session.displayedTerminalTitle) == .orderedAscending }
        guard reconcile else { return observed }
        let groupStore = SessionGroupStore(directory: paths.directory), saved = try groupStore.load()
        var refreshed = CodexGroupIdentity.refreshed(saved, live: observed)
        // A managed clear owns its write and checkpoint. Manual Claude clears
        // can reconcile directly from the registry of the original live process.
        let manual = refreshed.filter { !groupClearActive($0.id) }
        let claude = Dictionary(uniqueKeysWithValues: SessionGroupMatching.refreshedClaude(manual, live: observed).map { ($0.id, $0) })
        refreshed = refreshed.map { claude[$0.id] ?? $0 }
        var remaining:[TerminalProfileGroupAttachment]=[]
        for attachment in profileGroupAttachments where attachment.expires > Date() {
            guard let gi=refreshed.firstIndex(where:{$0.id==attachment.groupID}),
                  let mi=refreshed[gi].members.firstIndex(where:{$0.id==attachment.memberID}) else{continue}
            // A user's intervening identity edit invalidates this receipt.
            let member=refreshed[gi].members[mi]
            guard member.agent.rawValue==attachment.entry.agent,member.cwd==attachment.entry.cwd,
                  member.conversationID==attachment.entry.conversationID else{continue}
            guard let live=attachment.match(observed) else{remaining.append(attachment);continue}
            guard !refreshed[gi].members.contains(where:{$0.id != member.id && $0.runtimeID==live.id}) else{continue}
            refreshed[gi].members[mi].tabShell=live.tabShell
            refreshed[gi].members[mi].runtimeID=live.id
            refreshed[gi].members[mi].providerHome=live.providerHome ?? TerminalProfileGroup.normalizedHome(attachment.entry.providerHome,agent:attachment.entry.agent)
        }
        if refreshed != saved { try groupStore.save(refreshed, expected: saved) }
        profileGroupAttachments=remaining
        return observed
    }

    /// Per-call conversation evidence takes precedence over the MCP host process.
    /// A daemon can serve multiple conversations and need not have a visible TUI.
    private func sessionGroupCaller(_ object: JSONObject, observed: [SessionGroupLiveSession], recovery: Bool = false) throws -> (session: SessionGroupLiveSession, attribution: String) {
        let claimed = object["conversationID"] as? String
        guard claimed == nil || UUID(uuidString: claimed!) != nil else { throw RemoteHTTPError(400, "현재 대화의 UUID를 확인해주세요.") }
        if object["agentKind"] as? String == AgentKind.codex.rawValue,
           let proof = object["codexCallerConversationID"] as? String,
           let uuid = UUID(uuidString: proof), let home = object["codexCallerHome"] as? String,
           home.hasPrefix("/"), !home.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) {
            guard let claimed, UUID(uuidString: claimed) == uuid else {
                throw RemoteHTTPError(409, "지정한 대화 ID가 이 Codex 호출의 대화와 다릅니다.")
            }
            let attribution = object["codexCallerSource"] as? String == "codex_exec_context" ? "codex_exec_context" : "codex_mcp_metadata"
            let endpoints = observed.filter { $0.session.agent == .codex && $0.session.phase != .ended &&
                $0.providerHome == home && $0.conversationID.flatMap(UUID.init(uuidString:)) == uuid }
            if endpoints.count == 1, let endpoint = endpoints.first { return (endpoint, attribution) }
            let caller = AgentSession(id: "codex-mcp:" + home + ":" + uuid.uuidString, agent: .codex, pid: 0,
                                      started: "", tty: "", cwd: "", terminal: .unknown)
            return (.init(session: caller, conversationID: uuid.uuidString, providerHome: home), attribution)
        }
        if let direct = (object["sessionID"] as? String).flatMap({ id in observed.first { $0.id == id } }) {
            if let claimed, !(recovery && direct.conversationID == nil), UUID(uuidString: claimed) != direct.conversationID.flatMap(UUID.init(uuidString:)) {
                throw RemoteHTTPError(409, "지정한 대화 ID가 현재 세션과 다릅니다. conversationID에는 이 도구를 호출하는 세션 자신의 대화 ID만 넣을 수 있습니다. 다른 구성원의 대화 ID와 memberID는 get_session_groups 결과의 members에서 확인하세요.")
            }
            return (direct, "process")
        }
        guard object["agentKind"] as? String != AgentKind.agy.rawValue, let claimed, let uuid = UUID(uuidString: claimed),
              let kindText = object["agentKind"] as? String, let kind = AgentKind(rawValue: kindText), kind != .shell else {
            throw RemoteHTTPError(409, "공유 서버에서 현재 세션을 자동 확인하지 못했습니다. 현재 대화 UUID를 지정해주세요.")
        }
        let claimedHome = kind == .codex ? object["codexCallerHome"] as? String : nil
        let matches = observed.filter { $0.session.agent == kind && $0.providerHome != nil &&
            (claimedHome == nil || claimedHome == $0.providerHome) && $0.conversationID.flatMap(UUID.init(uuidString:)) == uuid }
        if matches.isEmpty, kind == .codex, let home = object["codexCallerHome"] as? String,
           home.hasPrefix("/"), (object["codexCallerConversationID"] as? String).flatMap(UUID.init(uuidString:)) == uuid {
            let caller = AgentSession(id: "codex-mcp:" + home + ":" + uuid.uuidString, agent: .codex, pid: 0,
                                      started: "", tty: "", cwd: "", terminal: .unknown)
            let attribution = object["codexCallerSource"] as? String == "codex_exec_context" ? "codex_exec_context" : "codex_mcp_metadata"
            return (.init(session: caller, conversationID: uuid.uuidString, providerHome: home), attribution)
        }
        guard matches.count == 1, let found = matches.first else {
            throw RemoteHTTPError(409, "지정한 대화에 일치하는 실행 세션을 유일하게 확인하지 못했습니다.")
        }
        return (found, "provided_conversation_id")
    }

    private func groupMemberIsCaller(_ member: SessionGroupMember, caller: SessionGroupLiveSession, observed: [SessionGroupLiveSession]) -> Bool {
        if caller.session.pid == 0, caller.session.agent == .codex {
            return member.agent == .codex && member.providerHome == caller.providerHome &&
                UUID(uuidString: member.conversationID) == caller.conversationID.flatMap(UUID.init(uuidString:))
        }
        return SessionGroupMatching.match(member, in: observed)?.id == caller.id
    }

    /// Reading membership and repairing an ID may use the exact saved process.
    /// This does not authorize messages, tasks or consuming reports until the conversation is verified.
    private func groupRecoveryCaller(_ member: SessionGroupMember, caller: SessionGroupLiveSession, observed: [SessionGroupLiveSession]) -> Bool {
        groupMemberIsCaller(member, caller: caller, observed: observed) ||
            (caller.conversationID == nil && member.runtimeID == caller.id &&
             SessionGroupMatching.connection(member, in: observed)?.id == caller.id)
    }

    private func canReconnectGroupMember(_ member: SessionGroupMember, group: SessionGroup, caller: SessionGroupLiveSession,
                                         callerMember: SessionGroupMember, observed: [SessionGroupLiveSession]) -> Bool {
        guard SessionGroupMatching.connection(member, in: observed) != nil ||
                (groupMemberIsCaller(callerMember, caller: caller, observed: observed) &&
                 SessionGroupMatching.replacement(member, in: observed, selected: nil) != nil) else { return false }
        return member.id == callerMember.id || group.canDirect(callerMember.id, worker: member.id) ||
            group.leaderMemberID == nil
    }

    private func reconnectGroupMember(_ object: JSONObject, groupID: UUID, memberID: UUID) async throws -> JSONObject {
        let observed = try await sessionGroupSessions()
        let (caller, _) = try sessionGroupCaller(object, observed: observed, recovery: true)
        guard let group = try SessionGroupStore(directory: paths.directory).load().first(where: { $0.id == groupID }),
              let callerMember = group.members.first(where: { groupRecoveryCaller($0, caller: caller, observed: observed) }),
              let member = group.members.first(where: { $0.id == memberID }) else {
            throw RemoteHTTPError(403, "현재 세션의 그룹과 구성원을 확인해주세요. get_session_groups로 다시 조회할 수 있습니다.")
        }
        guard canReconnectGroupMember(member, group: group, caller: caller, callerMember: callerMember, observed: observed) else {
            throw RemoteHTTPError(409, "재연결할 수 있는 원래 터미널을 확인하지 못했거나 재연결 권한이 없습니다. canReconnect가 true인 구성원만 재연결할 수 있습니다. 종료된 터미널은 자동으로 다시 실행하지 않습니다.")
        }
        let refreshed = try await refreshSessionGroupMemberID(groupID: groupID, memberID: memberID, expectedGroup: group)
        // A group-list observation already in flight can predate the new status card.
        let fresh = try await readSessionGroupSessions(reconcile: false)
        guard let updated = try SessionGroupStore(directory: paths.directory).load().first(where: { $0.id == groupID })?.members.first(where: { $0.id == memberID }),
              let live = SessionGroupMatching.match(updated, in: fresh), live.id == updated.runtimeID,
              let id = live.conversationID, UUID(uuidString: id) == UUID(uuidString: refreshed.conversationID) else {
            throw RemoteHTTPError(409, "갱신 후 연결이 바뀌어 재연결을 확인하지 못했습니다. get_session_groups로 다시 확인해주세요.")
        }
        return ["groupID": groupID.uuidString, "memberID": memberID.uuidString, "connected": true,
                "conversationID": id, "transport": "local_terminal", "message": "같은 Mac의 원래 터미널에서 현재 세션 ID와 연결을 확인했습니다."]
    }

    private func refreshGroupWaits() {
        groupWaitTimer?.cancel()
        groupWaitTimer = nil
        let delay: TimeInterval
        do {
            let box = try groupMailbox()
            if try box.pendingCount > 0 || !box.recoverableClaudeQuestions().isEmpty { scheduleGroupMailboxDelivery() }
            guard try box.hasUnresolvedWaits() else { return }
            let state = try groupOrchestration()
            try box.transaction { try box.reconcileWaits(assignments: state.assignments) }
            if try box.pendingCount > 0 { scheduleGroupMailboxDelivery() }
            guard let deadline = try box.nextWaitDeadline() else { return }
            delay = max(0.01, deadline.timeIntervalSinceNow)
        } catch { delay = 5 }
        groupWaitTimer = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            self?.refreshGroupWaits()
        }
    }

    private func waitRequest(_ object: JSONObject, id: UUID, group: UUID, member: UUID, question: UUID? = nil,
                             box: SessionGroupMailbox, state: SessionGroupOrchestration) throws -> GroupWaitRequest {
        let task: UUID?
        if let explicit = try GroupWaitRequest.uuid(object, "taskID") { task = explicit }
        else if let stored = try box.waitRecord(id) { task = stored.request.task }
        else {
            let current = state.current(groupID: group, workerMemberID: member)
            task = current?.status == .working ? current?.id : nil
        }
        return try GroupWaitRequest.parse(object, id: id, group: group, member: member, task: task, question: question)
    }

    private func groupWaitAction(_ tool: String, object: JSONObject) async throws -> JSONObject {
        guard let group = try GroupWaitRequest.uuid(object, "groupID") else { throw RemoteHTTPError(400, "groupID를 지정해주세요.") }
        let (_, caller) = try await groupMailboxCaller(object, groupID: group)
        let box = try groupMailbox()
        var state = try groupOrchestration()
        if tool == "complete_group_task" {
            guard let id = try GroupWaitRequest.uuid(object, "taskID"),
                  let body = object["summary"] as? String, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, body.count <= 600,
                  let item = state.assignments.first(where: { $0.id == id && $0.groupID == group && $0.workerMemberID == caller.id && $0.isDelivered }) else {
                throw RemoteHTTPError(400, "본인에게 배정된 작업 ID와 1~600자의 완료 요약을 지정해주세요.")
            }
            if item.status == .working {
                guard try !box.visibleWaits(group).contains(where: { $0.request.task == id && $0.state == "waiting" }) else { throw RemoteHTTPError(409, "해결되지 않은 작업 대기가 있습니다.") }
                state.complete(id: id, completion: WorkCompletion(id: id.uuidString, summary: body))
                try saveGroupOrchestration(state)
                scheduleGroupDelivery()
            } else if item.status == .superseded || item.summary != WorkCompletion(id: id.uuidString, summary: body).summary {
                throw RemoteHTTPError(409, "작업이 교체됐거나 이미 다른 결과로 완료됐습니다.")
            }
            return ["taskID": id.uuidString, "completed": true]
        }
        guard let id = try GroupWaitRequest.uuid(object, "waitID") else { throw RemoteHTTPError(400, "재시도에도 유지할 waitID를 지정해주세요.") }
        let row: GroupWaitRecord
        if tool == "update_group_wait" {
            guard let action = object["action"] as? String, ["externalReady","cancel"].contains(action) else { throw RemoteHTTPError(400, "대기 변경 동작을 확인해주세요.") }
            row = try box.changeWait(id, group: group, member: caller.id, externalReady: action == "externalReady", assignments: state.assignments)
        } else {
            let request = try waitRequest(object, id: id, group: group, member: caller.id, box: box, state: state)
            row = try box.transaction { try box.registerWait(request, assignments: state.assignments) }
        }
        refreshGroupWaits()
        return row.json
    }

    private func groupMailbox() throws -> SessionGroupMailbox {
        if let groupMailboxStore { return groupMailboxStore }
        let value = try SessionGroupMailbox(directory: paths.directory)
        groupMailboxStore = value
        return value
    }

    /// Asks for nicknames and roles: the leader names every listed member, or in a group without a
    /// leader each listed member names itself. Returns the number of requests queued; each costs one short
    /// turn that only calls set_group_member_title. `byUser` is a press of a request button in the graph:
    /// the user can ask again at any time, for one member or the whole group, even when names exist.
    /// Adding members (`byUser` false) asks once per member and skips members asked before.
    @discardableResult
    public func requestSessionGroupNicknames(groupID: UUID, memberIDs: [UUID], byUser: Bool = false) throws -> Int {
        guard let group = try SessionGroupStore(directory: paths.directory).load().first(where: { $0.id == groupID }) else { return 0 }
        func key(_ member: UUID) -> String { "groupNicknameRequested:\(groupID.uuidString):\(member.uuidString)" }
        let targets = group.members.filter { member in memberIDs.contains(member.id) && (byUser || store.value(key(member.id)) == nil) }
        guard !targets.isEmpty else { return 0 }
        let box = try groupMailbox()
        var requests: [(recipient: UUID, text: String, sourceKey: String?)] = []
        let leader = group.leaderMemberID.flatMap { id in group.members.contains(where: { $0.id == id }) ? id : nil }
        let howTo = "role에는 맡은 일을 한 줄(120자 이내)로, title에는 그 역할을 나타내는 3~20자 이름을 서로 겹치지 않게 적어. "
            + "도구는 AutoApprove MCP의 set_group_member_title(groupID, memberID, title, role)이고 Claude Code에서는 mcp__autoapprove__set_group_member_title이야. 안 보이면 ToolSearch로 불러와. "
            + "이름과 역할 설정 말고 다른 작업은 하지 마."
        if byUser {
            // The user pressed a button for this, so it is typed as the user's own short request; the text says
            // which button sent it. Members, IDs and current names come from get_group_status, keeping it short.
            let button = targets.count == 1 ? "'이 구성원 이름 다시 정하기'" : "'전체 다시 정하기'"
            let scope = targets.count == 1
                ? "구성원 '\(targets[0].title)'(memberID \(targets[0].id.uuidString)) 한 명의"
                : "구성원 \(targets.count)명의"
            if let leader {
                requests.append((leader, "AutoApprove 대화 그래프에서 \(button) 버튼을 눌러 보내는 내 요청이야. 그룹 '\(group.name)'(groupID \(group.id.uuidString)) \(scope) 이름과 역할을 지금 하는 일에 맞게 다시 정해 줘. get_group_status로 구성원 memberID와 지금 이름, 역할을 확인하고 구성원마다 설정해. " + howTo,
                                 SessionGroupMessage.userButtonSourcePrefix + "rename:" + UUID().uuidString))
            } else {
                for member in targets {
                    requests.append((member.id, "AutoApprove 대화 그래프에서 \(button) 버튼을 눌러 보내는 내 요청이야. 그룹 '\(group.name)'(groupID \(group.id.uuidString))에서 이 세션(memberID \(member.id.uuidString))의 이름과 역할을 지금 하는 일에 맞게 다시 정해 줘. get_group_status로 다른 구성원의 이름을 확인해 겹치지 않게 해. " + howTo,
                                     SessionGroupMessage.userButtonSourcePrefix + "rename:" + UUID().uuidString))
                }
            }
        } else {
            // Sent by AutoApprove when members are added; it stays a notice, and the recipient may decline it.
            func line(_ member: SessionGroupMember) -> String {
                "memberID \(member.id.uuidString), \(member.agent.title), 작업 폴더 \(member.cwd), 지금 이름 \(member.title.isEmpty ? "(없음)" : member.title), 지금 역할 \(member.role ?? "(없음)")"
            }
            let origin = "그룹에 구성원이 추가되어 AutoApprove가 한 번 보내는 요청입니다."
            let tool = "도구는 AutoApprove MCP 서버의 set_group_member_title(groupID, memberID, title, role)이고, Claude Code에서는 mcp__autoapprove__set_group_member_title입니다. 목록에 보이지 않으면 ToolSearch로 불러오세요."
            let rule = "구성원마다 지금 하는 일을 확인해 role에 맡은 일을 한 줄(120자 이내)로 적고, title에는 그 역할을 나타내는 3~20자 이름을 서로 겹치지 않게 적습니다. 이름과 역할을 정하는 것 말고 다른 작업은 하지 마세요."
            if let leader {
                requests.append((leader, "[AutoApprove 닉네임 요청] \(origin) 그룹 '\(group.name)'(groupID \(group.id.uuidString))의 아래 구성원 \(targets.count)명의 이름과 역할을 정해 설정해 주세요. \(rule) \(tool) 대상: " + targets.map(line).joined(separator: " / "), nil))
            } else {
                for member in targets {
                    requests.append((member.id, "[AutoApprove 닉네임 요청] \(origin) 그룹 '\(group.name)'(groupID \(group.id.uuidString))에서 이 세션(memberID \(member.id.uuidString))의 이름과 역할을 정해 설정해 주세요. \(rule) \(tool) 지금 정보: " + line(member), nil))
                }
            }
        }
        for request in requests {
            _ = try box.enqueue(groupID: group.id, senderID: request.recipient, recipientID: request.recipient, kind: .notice,
                                text: request.text, sourceKey: request.sourceKey)
        }
        for member in targets { try store.set(key(member.id), String(Date().timeIntervalSince1970)) }
        log(AuditEvent(sessionID: "", summary: "세션 그룹 '\(group.name)' 닉네임 요청", outcome: "구성원 \(targets.count)명의 이름과 역할 정하기 요청",
                       source: "세션 그룹", tool: "set_group_member_title"))
        scheduleGroupMailboxDelivery()
        return requests.count
    }

    /// Stores the role a leader set with a nickname. Retries on a concurrent edit of the group store.
    private func setGroupMemberRole(groupID: UUID, memberID: UUID, role: String) throws {
        let store = SessionGroupStore(directory: paths.directory)
        for _ in 0..<3 {
            let latest = try store.load()
            guard let gi = latest.firstIndex(where: { $0.id == groupID }),
                  let mi = latest[gi].members.firstIndex(where: { $0.id == memberID }) else {
                throw AppError.message("역할을 저장할 구성원을 찾지 못했습니다.")
            }
            guard latest[gi].members[mi].role != role else { return }
            var next = latest; next[gi].members[mi].role = role
            do { try store.save(next, expected: latest); publish(); return } catch { continue }
        }
        throw AppError.message("그룹 정보가 계속 바뀌어 역할을 저장하지 못했습니다.")
    }

    public func queueSessionGroupMessage(groupID: UUID, senderID: UUID, recipientID: UUID,
                                         text: String, expectsReply: Bool) throws -> UUID {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, body.count <= SessionGroupOrchestration.maximumTaskLength, !body.contains("\0") else {
            throw AppError.message("메시지를 1~4000자로 입력해주세요.")
        }
        guard !groupClearActive(groupID),
              let group = try SessionGroupStore(directory: paths.directory).load().first(where: { $0.id == groupID }),
              senderID != recipientID,
              let sender = group.members.first(where: { $0.id == senderID }), UUID(uuidString: sender.conversationID) != nil,
              let recipient = group.members.first(where: { $0.id == recipientID }), UUID(uuidString: recipient.conversationID) != nil else {
            throw AppError.message("현재 그룹의 서로 다른 두 대화를 선택해주세요.")
        }
        let message = try groupMailbox().enqueue(id: UUID(), groupID: groupID, senderID: senderID, recipientID: recipientID,
                                                 kind: expectsReply ? .question : .message, text: body)
        scheduleGroupMailboxDelivery()
        return message.id
    }

    public func queueSessionGroupReply(groupID: UUID, questionID: UUID, text: String) throws -> UUID {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, body.count <= SessionGroupOrchestration.maximumTaskLength, !body.contains("\0") else {
            throw AppError.message("답변을 1~4000자로 입력해주세요.")
        }
        guard !groupClearActive(groupID),
              let group = try SessionGroupStore(directory: paths.directory).load().first(where: { $0.id == groupID }) else {
            throw AppError.message("현재 그룹을 확인한 뒤 다시 시도해주세요.")
        }
        let box = try groupMailbox()
        guard let question = try box.message(questionID), question.kind == .question, question.groupID == groupID,
              question.lastResult != "superseded",
              group.members.contains(where: { $0.id == question.senderID }),
              group.members.contains(where: { $0.id == question.recipientID }) else {
            throw AppError.message("현재 그룹의 원래 질문과 구성원을 확인할 수 없습니다.")
        }
        let answer = try recordSessionGroupAnswer(box, questionID: questionID, messageID: UUID(), groupID: groupID,
                                                 senderID: question.recipientID, recipientID: question.senderID, body: body)
        scheduleGroupMailboxDelivery()
        return answer.id
    }

    /// One operator-initiated terminal attempt using the original question and receipt ID.
    public func deliverSessionGroupQuestion(groupID: UUID, questionID: UUID) async throws {
        guard !snapshot.paused, !remoteInputStopped else {
            throw AppError.message("AutoApprove가 일시 정지되어 있습니다.")
        }
        guard activeGroupMailboxMessages.insert(questionID).inserted else {
            throw AppError.message("이 질문의 전달이 이미 진행 중입니다.")
        }
        defer { activeGroupMailboxMessages.remove(questionID) }

        let box = try groupMailbox()
        let observed = try await sessionGroupSessions()
        guard let question = try box.unansweredQuestion(questionID, in: groupID) else {
            throw AppError.message("현재 그룹에서 아직 답변되지 않은 질문을 찾을 수 없습니다.")
        }
        let retryAt = Date().addingTimeInterval(groupMailboxReminderInterval)
        try box.noteManualQuestionAttempt(questionID, result: "direct_attempting", retryAt: retryAt, starting: true)
        do {
            try await sendGroupMailboxNotice(question, observed: observed, manualQuestion: true)
        } catch {
            let result = (error as? RemoteHTTPError)?.diagnostics?["delivery"]
            if result == "not_started" {
                try box.noteManualQuestionAttempt(questionID, result: question.lastResult,
                                                  error: question.lastError, retryAt: question.nextAttemptAt)
                throw error
            }
            try box.noteManualQuestionAttempt(questionID, result: "direct_unknown", error: error.localizedDescription, retryAt: retryAt)
            throw AppError.message("터미널 제출을 확인하지 못했습니다. 대상 터미널을 확인해주세요.")
        }
        try box.noteManualQuestionAttempt(questionID, result: "direct_submitted", retryAt: retryAt)
    }

    private func recordSessionGroupAnswer(_ box: SessionGroupMailbox, questionID: UUID, messageID: UUID?,
                                          groupID: UUID, senderID: UUID, recipientID: UUID, body: String) throws -> SessionGroupMessage {
        let state = try groupOrchestration()
        let answer = try box.transaction {
            let message = try box.answer(questionID, id: messageID, group: groupID, sender: senderID, recipient: recipientID, text: body)
            try box.reconcileWaits(assignments: state.assignments, group: groupID)
            return message
        }
        refreshGroupWaits()
        return answer
    }

    private func enqueueGroupMessage(_ object: JSONObject, groupID: UUID, memberID: UUID, text: String, kind: SessionGroupMessage.Kind) async throws -> JSONObject {
        let line = SessionGroupOrchestration.oneLine(text)
        guard !line.isEmpty, text.count <= SessionGroupOrchestration.maximumTaskLength, !text.contains("\0"),
              kind != .message || SessionGroupOrchestration.commandPrefix(line) == nil else {
            throw RemoteHTTPError(400, "메시지 내용은 1~\(SessionGroupOrchestration.maximumTaskLength)자로 지정해주세요. 일반 메시지는 명령 접두사로 시작할 수 없습니다.")
        }
        let requestedID = (object["messageID"] as? String).flatMap(UUID.init(uuidString:))
        guard object["messageID"] == nil || requestedID != nil else { throw RemoteHTTPError(400, "messageID는 UUID로 지정해주세요.") }
        let observed = try await sessionGroupSessions()
        let (caller, _) = try sessionGroupCaller(object, observed: observed)
        guard let group = try SessionGroupStore(directory: paths.directory).load().first(where: { $0.id == groupID }),
              let sender = group.members.first(where: { groupMemberIsCaller($0, caller: caller, observed: observed) }),
              UUID(uuidString: sender.conversationID) != nil, caller.conversationID.flatMap(UUID.init(uuidString:)) != nil,
              let recipient = group.members.first(where: { $0.id == memberID }), recipient.id != sender.id else {
            throw RemoteHTTPError(403, "확인된 현재 세션에서 같은 그룹의 다른 구성원에게만 보낼 수 있습니다.")
        }
        // Accept while the recipient is busy/disconnected. COMMIT precedes this success response.
        let box = try groupMailbox()
        let blocking = try GroupWaitRequest.flag(object, "blocksProgress")
        let reply = try GroupWaitRequest.uuid(object, "inReplyTo")
        guard !blocking || (kind == .question && requestedID != nil), reply == nil || kind == .reply else {
            throw RemoteHTTPError(400, "필수 질문에는 messageID를, 답변에는 원래 질문 ID를 지정해주세요.")
        }
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var wait: GroupWaitRecord?
        let message: SessionGroupMessage
        if blocking, let id = requestedID {
            let state = try groupOrchestration()
            let request = try waitRequest(object, id: id, group: groupID, member: sender.id, question: id, box: box, state: state)
            message = try box.transaction {
                let m = try box.insertMessage(id: id, groupID: groupID, senderID: sender.id, recipientID: recipient.id, kind: .question, text: body, sourceKey: "decision:" + id.uuidString)
                guard m.text == body else { throw RemoteHTTPError(409, "같은 ID의 질문 내용이 다릅니다.") }
                wait = try box.registerWait(request, assignments: state.assignments)
                return m
            }
            refreshGroupWaits()
        } else if let reply {
            message = try recordSessionGroupAnswer(box, questionID: reply, messageID: requestedID, groupID: groupID,
                                                   senderID: sender.id, recipientID: recipient.id, body: body)
        } else {
            message = try box.enqueue(id: requestedID, groupID: groupID, senderID: sender.id, recipientID: recipient.id, kind: kind, text: body)
        }
        scheduleGroupMailboxDelivery()
        var output: JSONObject = ["accepted": true, "messageID": message.id.uuidString, "receipt": message.json,
                "delivered": message.acknowledgedAt != nil, "transport": "local_mailbox", "networkRequired": false,
                "message": "로컬 수신함에 저장했습니다. accepted는 접수이며 수신 완료가 아닙니다. 같은 메시지를 재호출할 때 이 messageID를 유지하세요. 전달 결과는 로컬 수신함에서 확인할 수 있습니다."]
        if let wait { output["wait"] = wait.json }
        return output
    }

    private func groupMailboxCaller(_ object: JSONObject, groupID: UUID) async throws -> (SessionGroup, SessionGroupMember) {
        let observed = try await sessionGroupSessions()
        let (caller, _) = try sessionGroupCaller(object, observed: observed)
        guard let group = try SessionGroupStore(directory: paths.directory).load().first(where: { $0.id == groupID }),
              let member = group.members.first(where: { groupMemberIsCaller($0, caller: caller, observed: observed) }),
              UUID(uuidString: member.conversationID) != nil else { throw RemoteHTTPError(403, "현재 세션의 그룹 수신함만 조회하거나 수신 확인할 수 있습니다.") }
        return (group, member)
    }

    private func groupMailboxSummary(groupID: UUID, memberID: UUID) -> JSONObject {
        do {
            let inbox = try groupMailbox().list(groupID: groupID, memberID: memberID, limit: 21)
            let outbox = try groupMailbox().list(groupID: groupID, memberID: memberID, outbox: true, limit: 21)
            return ["inbox": inbox.prefix(20).map(\.json), "outbox": outbox.prefix(20).map(\.json),
                    "inboxHasMore": inbox.count > 20, "outboxHasMore": outbox.count > 20,
                    "message": "조회는 수신 확인이 아닙니다. 받은 messageID를 ack_group_messages로 확인하세요. get_group_messages에서 다음 페이지와 수신 완료 상태를 조회할 수 있습니다."]
        } catch { return ["error": error.localizedDescription] }
    }

    private func scheduleGroupMailboxDelivery() {
        guard !remoteInputStopped else { return }
        if groupMailboxTask != nil { groupMailboxSignal.notify(); return }
        let change = groupMailboxSignal.observe()
        groupMailboxTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                var delay = self.groupMailboxPollInterval
                do {
                    let box = try self.groupMailbox()
                    let ttl = TimeInterval(self.groupMessageTTLMinutes * 60)
                    var expiration = try box.nextExpiration(ttl: ttl)
                    if let due = expiration, due <= Date() {
                        try box.expireUnconfirmed(createdThrough: Date().addingTimeInterval(-ttl))
                        expiration = try box.nextExpiration(ttl: ttl)
                        self.refreshGroupWaits()
                        self.publish()
                    }
                    let questions = try box.recoverableClaudeQuestions()
                    let hasDelivery = try box.hasNotificationWork || box.hasPendingReceipts || !questions.isEmpty
                    guard hasDelivery || expiration != nil else { self.groupMailboxTask = nil; return }
                    if !hasDelivery, let expiration { delay = max(0.1, expiration.timeIntervalSinceNow) }
                    if !self.snapshot.paused, Date().timeIntervalSince(self.groupRecoveryAt) >= 5, !questions.isEmpty,
                       self.sessions.values.contains(where: { $0.agent == .claude && $0.phase != .ended }) {
                        self.groupRecoveryAt = Date()
                        await self.recoverClaudeGroupQuestions(questions)
                    }
                    if hasDelivery { try await self.deliverGroupMailboxNotifications() }
                    if let expiration { delay = min(delay, max(0.1, expiration.timeIntervalSinceNow)) }
                } catch { /* Keep durable messages; query tools surface the storage error. */ }
                await change.waitForChange(timeout: delay)
            }
        }
    }

    private func recoverClaudeGroupQuestions(_ questions: [SessionGroupMessage]) async {
        guard !remoteInputStopped, let groups = try? SessionGroupStore(directory: paths.directory).load(),
              let live = try? await sessionGroupSessions(), !Task.isCancelled else { return }
        let reader = groupTranscriptReader
        for candidate in live where candidate.session.agent == .claude {
            guard let conversation = candidate.conversationID, let session = sessions[candidate.id],
                  ![.working, .approval, .input, .ended].contains(session.phase),
                  !session.pendingInTerminal, session.backgroundMonitoring != true,
                  session.interruption?.needsAttention != true,
                  let group = groups.first(where: { group in
                      group.members.contains { SessionGroupMatching.match($0, in: live)?.id == candidate.id }
                  }), let member = group.members.first(where: { SessionGroupMatching.match($0, in: live)?.id == candidate.id }),
                  questions.contains(where: { $0.groupID == group.id && $0.recipientID == member.id }),
                  let observed = await Task.detached(priority: .utility, operation: { reader.recoverableGroupTurn(candidate) }).value,
                  !Task.isCancelled, !remoteInputStopped, let id = SessionGroupMessage.terminalMessageID(observed.prompt),
                  questions.contains(where: { $0.id == id && $0.groupID == group.id && $0.recipientID == member.id }),
                  let turn = try? groupMailbox().recoveryTurn(id, promptAt: observed.date, fallback: observed.response.id) else { continue }
            receiveGroupTurn(conversation: conversation, turn: turn, prompt: observed.prompt,
                             response: observed.response.originalResponse)
        }
    }

    private func deliverGroupMailboxNotifications() async throws {
        guard !snapshot.paused, !remoteInputStopped else { return }
        // Both checks read the group store and scan held messages; their thresholds are minutes long,
        // so running them on every pass of the loop only repeats the same answer.
        if Date().timeIntervalSince(groupHousekeepingAt) >= groupMailboxHousekeepingInterval {
            groupHousekeepingAt = Date()
            parkMessagesForRemovedMembers()
            notifyStalledSenders()
        }
        let overdue = try groupMailbox().overdueReceipts()
        var heads = try groupMailbox().heads()
        let idle = groupMailboxIdleSessions
        groupMailboxIdleSessions.removeAll()
        let now = Date()
        guard !overdue.isEmpty || heads.contains(where: { $0.nextAttemptAt <= now || (!idle.isEmpty && $0.lastResult == "not_started") }) else { return }
        let observed = try await sessionGroupSessions()
        if !overdue.isEmpty {
            await verifyGroupReceipts(overdue, observed: observed)
            heads = try groupMailbox().heads()
        }
        var eligible: [UUID: Set<UUID>] = [:]
        if !idle.isEmpty {
            for group in try SessionGroupStore(directory: paths.directory).load() {
                eligible[group.id] = Set(group.members.filter { member in
                    SessionGroupMatching.match(member, in: observed).map { idle.contains($0.id) } == true
                }.map(\.id))
            }
        }
        let dueAt = Date()
        for message in heads where message.nextAttemptAt <= dueAt ||
            (message.lastResult == "not_started" && eligible[message.groupID]?.contains(message.recipientID) == true) {
            guard !Task.isCancelled, !remoteInputStopped else { return }
            guard let current = try groupMailbox().message(message.id), current.acknowledgedAt == nil,
                  current.attempts == message.attempts, current.lastResult == message.lastResult,
                  activeGroupMailboxMessages.insert(message.id).inserted else { continue }
            defer { activeGroupMailboxMessages.remove(message.id) }
            // A typed message is never repeated on a timer. After the grace period the
            // receipt check either finds it in the conversation or proves it was lost.
            let receiptDue = Date().addingTimeInterval(groupMailboxReceiptGrace)
            try groupMailbox().noteAttempt(message.id, result: "direct_attempting", retryAt: receiptDue, increment: true)
            do {
                try await sendGroupMailboxNotice(message, observed: observed)
                try groupMailbox().noteAttempt(message.id, result: "direct_submitted", retryAt: receiptDue)
            } catch {
                let result = (error as? RemoteHTTPError)?.diagnostics?["delivery"] ?? "unknown"
                if result == "not_started" {
                    // Nothing was typed, so this try does not count toward the parking limit. A recipient
                    // that is working or waiting for an answer wakes the loop itself when it turns idle,
                    // so the timer is only a fallback for a missed event. Other holds (a draft in the
                    // composer, an unreadable screen) have no event and keep the short backoff.
                    let backoff = recipientWakesLoop(message, observed: observed) ? groupMailboxHeldFallback
                        : min(groupMailboxReminderInterval, max(groupMailboxPollInterval, Double(message.attempts + 1) * 5))
                    try groupMailbox().noteAttempt(message.id, result: result, error: error.localizedDescription, retryAt: Date().addingTimeInterval(backoff), increment: -1)
                } else {
                    try groupMailbox().noteAttempt(message.id, result: "direct_unknown", error: error.localizedDescription, retryAt: receiptDue)
                }
            }
        }
    }

    /// Tells the sender once when its message has waited too long without being typed. The notice is
    /// itself a `.notice`, which is never checked here, so senders that are also blocked cannot loop.
    private func notifyStalledSenders() {
        guard let box = try? groupMailbox(),
              let stalled = try? box.stalledForSenders(createdBefore: Date().addingTimeInterval(-groupStallNoticeAfter)),
              !stalled.isEmpty else { return }
        let groups = (try? SessionGroupStore(directory: paths.directory).load()) ?? []
        for message in stalled { noticeStalledSender(message, groups: groups) }
    }

    /// Whether the recipient is in a state that ends with an idle signal (`presentPhase` or a Claude hook).
    private func recipientWakesLoop(_ message: SessionGroupMessage, observed: [SessionGroupLiveSession]) -> Bool {
        guard let groups = try? SessionGroupStore(directory: paths.directory).load(),
              let recipient = groups.first(where: { $0.id == message.groupID })?.members.first(where: { $0.id == message.recipientID }),
              let live = SessionGroupMatching.match(recipient, in: observed), let session = sessions[live.id] else { return false }
        if let status = live.claudeRegisteredStatus, ["busy", "waiting"].contains(status) { return true }
        return [.working, .approval, .input].contains(session.phase) || session.pendingInTerminal
    }

    /// A recipient that left its group can never be matched to a terminal, so its messages used to be
    /// retried forever. They are parked instead: kept in the mailbox, out of the delivery queue, and the
    /// result is reported once to the sender, or to a leader when the sender left too.
    private func parkMessagesForRemovedMembers() {
        // An empty store is not taken as proof that every group was deleted.
        guard let box = try? groupMailbox(), let groups = try? SessionGroupStore(directory: paths.directory).load(),
              !groups.isEmpty else { return }
        let members = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, Set($0.members.map(\.id))) })
        guard let orphaned = try? box.queuedForMissingRecipients(members: members), !orphaned.isEmpty else { return }
        for message in orphaned {
            let group = groups.first { $0.id == message.groupID }
            let reason = group == nil ? "그룹이 삭제되어 전달하지 않고 수신함에 보관했습니다."
                                      : "받을 구성원이 그룹에서 빠져 전달하지 않고 수신함에 보관했습니다."
            guard (try? box.park(message.id, reason: reason)) != nil else { continue }
            let notified = group.flatMap { noticeRemovedRecipient(message, group: $0, box: box) }
            log(AuditEvent(sessionID: "", summary: "세션 그룹 메시지 \(message.id.uuidString.prefix(8))",
                           outcome: "그룹 메시지 전달 중단", source: "세션 그룹", tool: "group_mailbox",
                           request: reason + (notified.map { " \($0)에게 알렸습니다." } ?? " 알릴 구성원이 없습니다.")))
        }
    }

    /// Returns who was told: the sender, or a leader when the sender left the group too.
    private func noticeRemovedRecipient(_ message: SessionGroupMessage, group: SessionGroup, box: SessionGroupMailbox) -> String? {
        guard ![.notice, .waitNotice].contains(message.kind) else { return nil }
        let senderStays = group.members.contains { $0.id == message.senderID }
        guard let target = senderStays ? message.senderID
                : group.leaderMemberIDs.first(where: { id in group.members.contains { $0.id == id } }) else { return nil }
        let key = "removed:" + message.id.uuidString
        guard (try? box.message(sourceKey: key)) == nil else { return senderStays ? "보낸 구성원" : "그룹장" }
        let whose = senderStays ? "보낸 메시지" : "그룹에서 빠진 구성원 \(message.senderID.uuidString.prefix(8))이 보낸 메시지"
        let text = "[AutoApprove 전달 중단] \(whose)(messageID \(message.id.uuidString), \(message.kind.rawValue))를 받을 구성원 "
            + "\(message.recipientID.uuidString.prefix(8))이 그룹에서 빠져 전달하지 않았습니다. 메시지는 수신함에 보관했고 get_group_messages로 읽을 수 있습니다. "
            + "내용이 아직 필요하면 지금 그룹 구성원 가운데 맡을 구성원에게 다시 보내세요."
        guard (try? box.enqueue(groupID: group.id, senderID: target, recipientID: target, kind: .notice, text: text, sourceKey: key)) != nil else { return nil }
        return senderStays ? "보낸 구성원" : "그룹장"
    }

    private func noticeStalledSender(_ message: SessionGroupMessage, groups: [SessionGroup]) {
        guard [.question, .reply, .message].contains(message.kind), message.senderID != message.recipientID,
              let group = groups.first(where: { $0.id == message.groupID }),
              group.members.contains(where: { $0.id == message.senderID }),
              let box = try? groupMailbox(), (try? box.message(sourceKey: "stalled:" + message.id.uuidString)) == nil else { return }
        let recipient = group.members.first { $0.id == message.recipientID }?.title ?? "받는 구성원"
        let minutes = max(1, Int(Date().timeIntervalSince(message.createdAt) / 60))
        let reason = message.lastResult == "undelivered"
            ? "입력한 메시지가 여러 번 대화에 들어가지 않아 자동 입력을 멈췄습니다"
            : (message.lastError.flatMap { $0.isEmpty ? nil : $0 } ?? "받는 구성원의 앞선 메시지가 아직 전달되지 않아 순서를 기다리고 있습니다")
        let text = "[AutoApprove 전달 지연] 보낸 메시지(messageID \(message.id.uuidString), \(message.kind.rawValue))가 '\(recipient)'에게 \(minutes)분째 입력되지 않았습니다. 사유: \(reason) "
            + "메시지는 수신함에 보관되어 있고, 받는 쪽 입력창이 비면 자동으로 전달됩니다. 같은 내용을 다시 보내지 마세요. 진행에 꼭 필요하면 사용자에게 알리세요."
        _ = try? box.enqueue(groupID: group.id, senderID: message.senderID, recipientID: message.senderID, kind: .notice, text: text,
                             sourceKey: "stalled:" + message.id.uuidString)
    }

    /// Why a group message is held instead of typed, so the sender and the graph can tell a busy
    /// recipient or a draft apart from a composer the screen reader could not recognise.
    public nonisolated static func composerHoldReason(_ screen: String, agent: AgentKind, inputReason: String?) -> String {
        if let inputReason, !inputReason.isEmpty { return "터미널이 입력을 받을 수 없음(\(inputReason))" }
        if RemoteMessageReadiness.hasMenu(screen, agent: agent) { return "선택지나 확인 화면이 열려 있음" }
        if ActivityDetector.detect(screen, agent: agent).phase == .working { return "세션이 작업 중임" }
        let marker: Character = agent == .codex ? "›" : "❯"
        if let line = ActivityDetector.nonemptyTail(screen).last(where: { $0.first == marker }),
           !String(line.dropFirst()).trimmingCharacters(in: .whitespaces).isEmpty {
            return "입력창에 작성 중인 글이 있음"
        }
        return "입력창 모양을 판독하지 못함"
    }

    private enum GroupReceiptEvidence { case received, lost, unknown }

    /// Commit or redeliver typed messages whose receipt is overdue. Only proof of loss
    /// (an idle recipient, an empty composer and no trace of the prompt) types a message
    /// again, so a message that reached the model never costs a second turn.
    private func verifyGroupReceipts(_ messages: [SessionGroupMessage], observed: [SessionGroupLiveSession]) async {
        guard let box = try? groupMailbox() else { return }
        let groups = (try? SessionGroupStore(directory: paths.directory).load()) ?? []
        for message in messages {
            guard !Task.isCancelled, !remoteInputStopped else { return }
            let later = Date().addingTimeInterval(groupMailboxReceiptGrace)
            guard let recipient = groups.first(where: { $0.id == message.groupID })?.members.first(where: { $0.id == message.recipientID }),
                  let live = SessionGroupMatching.match(recipient, in: observed), let session = sessions[live.id] else {
                // An offline recipient proves nothing; keep the message and look again later.
                try? box.deferReceipt(message.id, until: later); continue
            }
            switch await groupReceiptEvidence(message, live: live, session: session) {
            case .received: break
            case .unknown: try? box.deferReceipt(message.id, until: later)
            case .lost:
                if (try? box.requeueLostSubmission(message.id, attemptLimit: groupMailboxDirectAttemptLimit)) == false,
                   let parked = try? box.message(message.id), parked.lastResult == "undelivered" {
                    log(AuditEvent(sessionID: session.id, summary: "세션 그룹 메시지 \(message.id.uuidString.prefix(8))",
                                   outcome: "그룹 메시지 자동 전달 중단", source: "세션 그룹", tool: "group_mailbox",
                                   request: parked.lastError))
                    noticeStalledSender(parked, groups: groups)
                }
            }
        }
    }

    private func groupReceiptEvidence(_ message: SessionGroupMessage, live: SessionGroupLiveSession, session: AgentSession) async -> GroupReceiptEvidence {
        // A busy, asking or occupied recipient may still be holding the typed prompt.
        guard ![.working, .approval, .input, .ended].contains(session.phase), !session.pendingInTerminal,
              !automaticInputBusy(session.id), !userInputHasPriority(session.id),
              let frame = try? await remoteTerminal(sessionID: session.id, realtime: true, textOnly: true),
              frame.inputReason == nil,
              session.agent == .codex ? CodexStatusIdentity.canQuery(frame.screen) : ClaudeComposerReadiness.isEmpty(frame.screen) else { return .unknown }
        guard let box = try? groupMailbox(), let current = try? box.message(message.id) else { return .unknown }
        if current.acknowledgedAt != nil { return .received }
        switch session.agent {
        case .claude:
            // The transcript is the durable record. A prompt carrying this ID means it arrived,
            // even when the hook missed it or the terminal reflowed its text.
            let reader = groupTranscriptReader
            if let turn = await Task.detached(priority: .utility, operation: { reader.recoverableGroupTurn(live) }).value,
               SessionGroupMessage.terminalMessageID(turn.prompt) == message.id {
                if let conversation = live.conversationID,
                   let id = try? box.recoveryTurn(message.id, promptAt: turn.date, fallback: turn.response.id) {
                    receiveGroupTurn(conversation: conversation, turn: id, prompt: turn.prompt, response: turn.response.originalResponse)
                }
                commitGroupReceipt(message)
                return .received
            }
            // With hooks, UserPromptSubmit commits every submitted prompt at once; without
            // them, the transcript above is the only trace. Either way nothing arrived.
            return .lost
        case .codex:
            // Proof needs an observation taken after the typing; an older one cannot show the prompt.
            guard let entry = codexTurns[session.id], let submitted = try? box.submittedAt(message.id),
                  entry.1 > submitted.addingTimeInterval(groupMailboxPollInterval) else { return .unknown }
            // Its completion commits it through the turn observer.
            if entry.0.userPrompt.flatMap(SessionGroupMessage.terminalMessageID) == message.id { return .unknown }
            return .lost
        default: return .unknown
        }
    }

    private func commitGroupReceipt(_ message: SessionGroupMessage) {
        guard let box = try? groupMailbox(), (try? box.message(message.id))?.acknowledgedAt == nil else { return }
        try? box.confirmDelivery(message)
        if [.report, .choiceQuestion].contains(message.kind) { try? applyGroupMessageAcknowledgements([message.id]) }
    }

    private func sendGroupMailboxNotice(_ message: SessionGroupMessage, observed: [SessionGroupLiveSession],
                                        manualQuestion: Bool = false) async throws {
        guard !groupClearActive(message.groupID) else { throw RemoteHTTPError(409, "그룹 초기화 중이어서 메시지를 수신함에 보관합니다.", diagnostics: ["delivery": "not_started"]) }
        guard let group = try SessionGroupStore(directory: paths.directory).load().first(where: { $0.id == message.groupID }),
              group.members.contains(where: { $0.id == message.senderID }),
              let recipient = group.members.first(where: { $0.id == message.recipientID }),
              UUID(uuidString: recipient.conversationID) != nil,
              let live = SessionGroupMatching.match(recipient, in: observed), live.conversationID.flatMap(UUID.init(uuidString:)) != nil,
              let current = sessions[live.id] else {
            throw RemoteHTTPError(409, "원래 그룹 구성원과 현재 터미널을 확인하지 못해 메시지를 보관하고 있습니다.", diagnostics: ["delivery": "not_started"])
        }
        func ready() throws {
            guard try SessionGroupStore(directory: paths.directory).load().first(where: { $0.id == group.id }) == group,
                  let now = sessions[current.id], !snapshot.paused, !remoteInputStopped,
                  !automaticInputBusy(current.id), !userInputHasPriority(current.id),
                  ![.approval, .input, .ended].contains(now.phase), !now.pendingInTerminal,
                  !message.deliversBody || now.phase != .working else {
                throw RemoteHTTPError(409, "그룹 연결·입력 상태가 바뀌어 메시지를 보관하고 있습니다.", diagnostics: ["delivery": "not_started"])
            }
        }
        try ready()
        // Every kind is typed with its body; the observed prompt is the delivery receipt.
        let prompt = message.terminalPrompt(senderTitle: group.members.first { $0.id == message.senderID }?.title ?? "")
        try await sendGroupLine(current, text: prompt, preflight: {
            let frame = try await self.remoteTerminal(sessionID: current.id, realtime: true, textOnly: true)
            let empty = current.agent == .codex ? CodexStatusIdentity.canQuery(frame.screen)
                : current.agent == .agy ? AgyComposerReadiness.isEmpty(frame.screen) : ClaudeComposerReadiness.isEmpty(frame.screen)
            let busyCodex = message.deliversBody && current.agent == .codex &&
                ActivityDetector.detect(frame.screen, agent: .codex).phase != .idle
            guard empty, !busyCodex, frame.inputReason == nil, !RemoteMessageReadiness.hasMenu(frame.screen, agent: current.agent) else {
                let reason = Self.composerHoldReason(frame.screen, agent: current.agent, inputReason: frame.inputReason)
                throw RemoteHTTPError(409, "대상의 빈 입력창을 확인하지 못해 메시지를 보관하고 있습니다. 사유: \(reason).", diagnostics: ["delivery": "not_started"])
            }
            try ready()
            let box = try self.groupMailbox()
            let latest = try manualQuestion ? box.unansweredQuestion(message.id, in: message.groupID) : box.message(message.id)
            guard let latest, manualQuestion || latest.acknowledgedAt == nil,
                  latest.acknowledgedAt != nil || Date().timeIntervalSince(latest.createdAt) < TimeInterval(self.groupMessageTTLMinutes * 60),
                  latest.lastResult == (message.deliversBody ? "direct_attempting" : "attempting") else {
                throw RemoteHTTPError(409, "메시지가 이미 처리되었습니다.", diagnostics: ["delivery": "not_started"])
            }
            if message.deliversBody {
                guard let conversation = live.conversationID else {
                    throw RemoteHTTPError(409, "현재 대화 ID를 확인해주세요.", diagnostics: ["delivery": "not_started"])
                }
                try box.recordSubmission(message.id, conversation: conversation, prompt: prompt)
            }
            // Retain the user's Claude hook delegation only for an authenticated task report/question.
            // A peer's free-form message must never acquire task/approval authority through this hint.
            if [.report, .choiceQuestion].contains(message.kind), message.sourceKey != nil,
               group.canDirect(message.recipientID, worker: message.senderID) {
                self.groupMailboxDelegations = self.groupMailboxDelegations.filter { Date().timeIntervalSince($0.value.at) < 600 }
                self.groupMailboxDelegations[current.id] = (message.id, Date(), group.name)
            }
        })
    }

    private func groupOrchestration() throws -> SessionGroupOrchestration {
        if let cached = groupOrchestrationCache { return cached }
        var loaded = SessionGroupOrchestration()
        if let text = store.value(SessionGroupOrchestration.storeKey) {
            do { loaded = try JSONDecoder().decode(SessionGroupOrchestration.self, from: Data(text.utf8)) }
            catch { throw AppError.message("세션 그룹 작업 기록을 읽지 못했습니다. 기존 기록을 유지합니다.") }
        }
        groupOrchestrationCache = loaded
        return loaded
    }

    /// Read-only task history for the management window.
    public func sessionGroupAssignments() throws -> [SessionGroupAssignment] { try groupOrchestration().assignments }

    public func sessionGroupConversations(_ id: UUID) throws -> SessionGroupConversationPage {
        try groupMailbox().conversations(groupID: id)
    }

    /// Present existing evidence on the graph without running a terminal probe.
    public func sessionGroupOperations(_ group: SessionGroup) throws -> [UUID: SessionGroupMemberOperation] {
        sessionGroupOperations(group, inboxes: try groupMailbox().inboxOperations(groupID: group.id))
    }

    /// Combines inbox summaries (which a window may read on its own connection, off the main
    /// thread) with the engine's in-memory session state. Reads no storage.
    public func sessionGroupOperations(_ group: SessionGroup, inboxes: [UUID: SessionGroupMailbox.InboxOperation]) -> [UUID: SessionGroupMemberOperation] {
        let stopped = snapshot.paused || remoteInputStopped
        let clearing = groupClearActive(group.id)
        let evidence = groupConnectionObservation.map { Date().timeIntervalSince($0.at) < 120 ? $0.sessions : [] } ?? []
        let current = evidence.compactMap { observed -> SessionGroupLiveSession? in
            guard let live = sessions[observed.id], live.phase != .ended, live.tty == observed.session.tty,
                  live.cwd == observed.session.cwd, live.codexApprovalBinding?.threadID == observed.session.codexApprovalBinding?.threadID,
                  !observed.codexIdentityFromMCP || groupMCPIdentity(for: live, home: observed.providerHome)?.conversationID ==
                    observed.conversationID.flatMap(UUID.init(uuidString:)) else { return nil }
            var value = observed
            value.session = live
            return value
        }
        return Dictionary(uniqueKeysWithValues: group.members.map { member in
            let live = UUID(uuidString: member.conversationID) == nil ? nil : SessionGroupMatching.match(member, in: current)
            let inbox = inboxes[member.id]
            let input = groupOperationInput(live, stopped: stopped, clearing: clearing)
            let count = inbox?.unacknowledgedCount ?? 0
            let blocked: Bool
            if case .deferred = input { blocked = true } else { blocked = false }
            return (member.id, SessionGroupMemberOperation(
                phase: live?.session.phase, input: input, unacknowledgedCount: count,
                lastAcknowledgedAt: inbox?.lastAcknowledgedAt, firstPendingAt: inbox?.firstPendingAt,
                lastDeliveryFailure: inbox?.lastDeliveryFailure,
                isDeliveryBlocked: count > 0 && (inbox?.hasParkedMessage == true ||
                    inbox?.hasNotificationHead == true && (blocked || inbox?.headDidNotStart == true))))
        })
    }

    private func groupOperationInput(_ live: SessionGroupLiveSession?, stopped: Bool, clearing: Bool) -> SessionGroupMemberOperation.Input {
        if stopped { return .deferred("AutoApprove 일시 정지") }
        if clearing { return .deferred("그룹 세션 초기화 중") }
        guard let live else { return .unverified }
        let session = live.session
        if live.claudeRegisteredStatus == "shell" { return .deferred("Claude Code에서 셸 명령 실행 중") }
        if [.approval, .input].contains(session.phase) || session.pendingInTerminal || session.osPermissionWaiting == true {
            return .deferred("터미널에서 승인 또는 입력 대기")
        }
        if automaticInputBusy(session.id) || sendingMessages.contains(session.id) || userInputHasPriority(session.id) {
            return .deferred("다른 터미널 입력 진행 중")
        }
        if session.phase == .working { return .deferred("세션 작업 중") }
        return session.phase == .idle ? .idle : .unverified
    }

    private func saveGroupOrchestration(_ state: SessionGroupOrchestration) throws {
        let data = try JSONEncoder().encode(state)
        try store.set(SessionGroupOrchestration.storeKey, String(decoding: data, as: UTF8.self))
        groupOrchestrationCache = state
        refreshGroupWaits()
        if !sessionGroupBadges.isEmpty { publish() }
    }

    /// Restarts each session in its own terminal and reopens the same conversation, so a CLI picks up
    /// new MCP tools and settings. An explicit restart ends the selected CLI even if its turn is active.
    /// With `resume`, each restarted session is then told to go on with the work it had in progress.
    @discardableResult
    public func restartSessions(_ ids: [String], resume: Bool = true) -> SessionRestartProgress {
        let ids = Array(Set(ids)).sorted().filter { sessionRestartTasks[$0] == nil }
        let now = Date()
        guard !ids.isEmpty else { return snapshot.sessionRestart ?? SessionRestartProgress(items: [], startedAt: now) }
        restartResumesWork = resume
        // Retrying keeps earlier results visible; only the retried sessions start over.
        var items = (snapshot.sessionRestart?.items ?? []).filter { !ids.contains($0.id) && ($0.phase == .done || !$0.phase.isFinished) }
        for id in ids {
            guard let session = sessions[id], session.phase != .ended, session.agent != .shell else { continue }
            items.append(SessionRestartItem(id: id, title: session.displayedTerminalTitle, phase: .waiting, message: "대화와 종료할 CLI를 확인하고 있습니다.", at: now))
            sessionRestartTasks[id] = Task { [weak self] in await self?.runSessionRestart(id, resume: resume) }
        }
        restartIdentityTask = Task { [weak self] in
            guard let self, let live = try? await self.sessionGroupSessions() else { return [:] }
            return Dictionary(live.compactMap { item in item.conversationID.map { (item.id, $0) } }, uniquingKeysWith: { first, _ in first })
        }
        let progress = SessionRestartProgress(items: items, startedAt: now)
        snapshot.sessionRestart = progress
        return progress
    }

    /// Stops restarts that have not exited their CLI yet. A CLI that already exited still gets its resume command.
    public func cancelSessionRestarts() {
        for item in snapshot.sessionRestart?.items ?? [] where item.phase == .waiting {
            sessionRestartTasks[item.id]?.cancel()
            updateRestart(item.id, .cancelled, "다시 시작을 취소했습니다.")
        }
    }

    /// Retries only the sessions whose restart failed and whose original CLI is still running.
    public func retryFailedSessionRestarts() {
        let failed = snapshot.sessionRestart?.items.filter { $0.phase == .failed && sessions[$0.id]?.phase != .ended && sessions[$0.id] != nil }.map(\.id) ?? []
        guard !failed.isEmpty else { return }
        restartSessions(failed, resume: restartResumesWork)
    }

    public func dismissSessionRestarts() {
        guard snapshot.sessionRestart?.isActive != true else { return }
        snapshot.sessionRestart = nil
    }

    private func updateRestart(_ id: String, _ phase: SessionRestartItem.Phase, _ message: String, newSessionID: String? = nil) {
        guard var progress = snapshot.sessionRestart, let index = progress.items.firstIndex(where: { $0.id == id }),
              !progress.items[index].phase.isFinished else { return }
        progress.items[index].phase = phase; progress.items[index].message = message; progress.items[index].updatedAt = Date()
        if let newSessionID { progress.items[index].newSessionID = newSessionID }
        snapshot.sessionRestart = progress
    }

    private func runSessionRestart(_ id: String, resume: Bool) async {
        defer { sessionRestartTasks.removeValue(forKey: id) }
        func fail(_ message: String) { updateRestart(id, .failed, message) }
        guard let original = sessions[id] else { return fail("세션을 찾지 못했습니다.") }
        guard let host = ScreenHost(kind: original.terminal), host == .terminal || host == .iterm || host == .pty,
              screenConnections[host]?.enabled == true, let adapter = screenAdapters[host], let restart = adapter.restart else {
            return fail("이 터미널(\(original.hostTitle))은 다시 시작 입력을 지원하지 않습니다. Terminal, iTerm2, AutoApprove PTY에서만 다시 시작합니다.")
        }
        func valid(_ value: String?) -> String? { value.flatMap { UUID(uuidString: $0) != nil ? $0 : nil } }
        var conversation = valid(original.agent != .codex ? original.providerID : questionThreadBySession[id] ?? original.codexApprovalBinding?.threadID)
        if conversation == nil, let status = groupStatusIdentities[id], status.session.started == original.started, status.session.tty == original.tty {
            conversation = valid(status.conversationID)
        }
        if conversation == nil { conversation = valid(await restartIdentityTask?.value[id]) }
        let reader = processReader
        guard let records = try? await Task.detached(operation: { try reader() }).value,
              let process = records.first(where: { $0.key == id && $0.agent == original.agent }) else {
            return fail("CLI 프로세스를 확인하지 못했습니다.")
        }
        // npm launchers put a node process between the shell and the CLI, so use the nearest shell on the same terminal.
        // A CLI that replaced its shell with exec has nothing to return to: a finished Terminal tab cannot run anything
        // again, and a new tab always lands at the end of the tab bar. Such a session is left untouched so its tab and
        // position stay as they are.
        let chain = ProcessDiscovery.ancestors(of: process.parent, records: records)
        guard let index = chain.firstIndex(where: { $0.tty == process.tty && SessionExitRecovery.isShell($0) }),
              chain[..<index].allSatisfy({ $0.tty == process.tty }) else {
            let shellless = chain.first.map { $0.tty == process.tty && ($0.executable as NSString).lastPathComponent == "login" } == true
            return fail(shellless
                ? "셸 없이 실행된 세션이라 같은 탭에서 다시 열 수 없어 건드리지 않았습니다. 세션 프로필로 다시 복원하면 다음부터 같은 탭에서 다시 시작합니다."
                : "CLI를 실행한 셸을 확인하지 못해 다시 시작하지 않았습니다.")
        }
        let shell = chain[index]
        let argumentsReader = processArgumentsReader, pathReader = processPathReader
        let resolved: String? = process.executable.hasPrefix("/") ? process.executable : await Task.detached(operation: { pathReader(process) }).value
        guard let executable = resolved else { return fail("CLI 실행 파일 경로를 확인하지 못했습니다.") }
        guard let argv = await Task.detached(operation: { argumentsReader(process) }).value, !argv.isEmpty else {
            return fail("CLI의 실행 옵션을 읽지 못했습니다.")
        }
        do { _ = try SessionRestartCommand.plan(agent: original.agent, executable: executable, argv: Array(argv.dropFirst()), conversationID: UUID().uuidString) }
        catch { return fail(error.localizedDescription) }
        let environment = await Task.detached(operation: { ProcessEnvironment.read(process) ?? [:] }).value

        guard !Task.isCancelled, !remoteInputStopped else { return }
        guard let current = sessions[id], current.phase != .ended else { return fail("다시 시작하기 전에 세션이 종료되었습니다.") }
        // Codex can show /status during a turn if its composer is empty.
        if conversation == nil, current.agent == .codex, !sendingMessages.contains(id), !automaticInputBusy(id) {
            updateRestart(id, .waiting, "터미널의 /status 화면에서 대화 ID를 확인하고 있습니다.")
            conversation = valid(try? await statusConversationID(current, waitForInput: false))
            if let conversation { groupStatusIdentities[id] = GroupStatusIdentity(session: current, conversationID: conversation, home: nil) }
        }
        // Last resort: the conversation the CLI was launched with. A later /clear may have started another one,
        // so the result says which ID was used.
        var launchedConversation = false
        if conversation == nil, current.phase == .idle {
            let tokens = Array(argv.dropFirst())
            let flags: Set<String> = current.agent == .claude ? ["--resume", "-r", "--session-id"] : ["resume"]
            if let index = tokens.firstIndex(where: { flags.contains($0) }), index + 1 < tokens.count, let id = valid(tokens[index + 1]) {
                conversation = id; launchedConversation = true
            }
        }
        guard let conversation else { return fail("대화 ID를 확인하지 못해 같은 대화로 다시 열 수 없습니다.") }
        let codexContext:CodexCLIContext?
        do {
            codexContext=original.agent == .codex
                ? try await Task.detached(priority:.utility) {try CodexOfficialExecutable.forSession(process)}.value:nil
            try Task.checkCancellation()
        } catch is CancellationError {return}
        catch {return fail(error.localizedDescription)}
        let plan: SessionRestartCommand.Plan
        do { plan = try SessionRestartCommand.plan(agent: original.agent, executable: codexContext?.executable ?? executable, argv: Array(argv.dropFirst()), conversationID: conversation) }
        catch { return fail(error.localizedDescription) }
        // Let an input transaction already in flight finish before ending this CLI.
        let settleUntil = Date().addingTimeInterval(5)
        while sendingMessages.contains(id) || automaticInputBusy(id) {
            guard !Task.isCancelled, !remoteInputStopped else { return }
            guard Date() < settleUntil else { return fail("전달 중인 입력이 끝나지 않아 CLI를 종료하지 않았습니다.") }
            updateRestart(id, .waiting, "전달 중인 입력이 끝나면 CLI를 종료합니다.")
            try? await Task.sleep(for: .milliseconds(150))
        }
        guard !Task.isCancelled,!remoteInputStopped else {return}
        guard let current = sessions[id], current.phase != .ended else { return fail("다시 시작하기 전에 세션이 종료되었습니다.") }
        let wasAutomatic = current.automatic
        let command:String
        do {command=try codexContext.map{try $0.terminalInvocation(Array(plan.arguments.dropFirst())).map(HookInstaller.quote).joined(separator:" ")}
            ?? plan.command(cwd:nil,environment:environment)}
        catch {return fail(error.localizedDescription)}
        // The PID must still be the same CLI and its shell must still be its ancestor before a signal is sent.
        let terminate = processTerminator
        guard let fresh = try? await Task.detached(operation: { try reader() }).value,
              fresh.contains(where: { $0.pid == process.pid && $0.started == process.started && $0.agent == original.agent && $0.tty == process.tty }),
              fresh.contains(where: { $0.pid == shell.pid && $0.started == shell.started && $0.tty == shell.tty }) else {
            return fail("CLI나 셸이 바뀌어 종료하지 않았습니다.")
        }
        guard !Task.isCancelled, !remoteInputStopped else { return }
        guard fresh.contains(where: { $0.key == process.key && ProcessDiscovery.ancestors(of: $0.parent, records: fresh)
            .contains(where: { $0.key == shell.key }) }),
              !sendingMessages.contains(id), !automaticInputBusy(id) else {
            return fail("CLI와 셸의 연결 또는 입력 상태가 바뀌어 종료하지 않았습니다.")
        }
        updateRestart(id, .exiting, "선택한 CLI에 종료 신호를 보내고 있습니다.")
        guard log(AuditEvent(sessionID: id, summary: "세션 다시 시작", outcome: "CLI 종료 신호 전달", source: host.title, context: AuditContext(session: current), request: command)) else {
            return fail("승인 내역을 저장하지 못해 종료하지 않았습니다.")
        }
        guard await Task.detached(operation: { terminate(process) }).value else { return fail("CLI에 종료 신호를 보내지 못했습니다.") }
        let manual = " 터미널에서 직접 실행해주세요: \(command)"

        // In place: the original shell must be back in the foreground with an empty prompt. The screen can
        // still be settling right after the CLI exits, so a changed screen is read again instead of failing.
        let context = SessionExitRecovery(session: current, process: process, shell: shell, conversationID: conversation)
        let target = ScreenTarget(tty: current.tty, handle: current.screenHandle, jobPIDs: [shell.pid], sourcePID: shell.pid, sourceStarted: shell.started)
        let until = Date().addingTimeInterval(45)
        var sent = false
        while !sent {
            guard Date() < until else { return fail("CLI가 종료된 뒤 셸 입력창을 확인하지 못했습니다." + manual) }
            try? await Task.sleep(for: .milliseconds(500))
            guard let live = try? await Task.detached(operation: { try reader() }).value, context.verifiedShell(in: live) != nil else { continue }
            let screen = try? await Task.detached(operation: { try adapter.readForValidation([target]).screens.first(where: { $0.tty == target.tty })?.contents }).value
            guard let prompt = screen ?? nil, SessionExitRecovery.emptyShellPrompt(prompt) else { continue }
            guard !restartTerminalBusy else { continue }
            restartTerminalBusy = true
            defer { restartTerminalBusy = false }
            updateRestart(id, .launching, "같은 터미널에서 같은 대화를 다시 열고 있습니다.")
            do {
                let delivery:TerminalDelivery=try await Task.detached {
                    try codexContext?.verifyUnchanged()
                    return try restart(target,prompt,command)
                }.value
                sent=delivery == .sent
            }
            catch { return fail("다시 시작 명령을 입력하지 못했습니다: \(error.localizedDescription)." + manual) }
        }
        log(AuditEvent(sessionID: id, summary: "세션 다시 시작", outcome: "같은 대화 다시 열기 입력", source: host.title, context: AuditContext(session: current), request: command))

        // Find the new CLI on that terminal and carry the automatic approval choice over.
        updateRestart(id, .confirming, "새 CLI 실행을 확인하고 있습니다.")
        let confirmUntil = Date().addingTimeInterval(60)
        while Date() < confirmUntil, !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            guard let live = try? await Task.detached(operation: { try reader() }).value else { continue }
            let index = ProcessDiscovery.index(live)
            let next = live.first { candidate in
                candidate.agent == original.agent && candidate.tty == process.tty && candidate.key != id &&
                ProcessDiscovery.ancestors(of: candidate.parent, byPID: index).contains { $0.pid == shell.pid && $0.started == shell.started }
            }
            guard let next, sessions[next.key] != nil else { continue }
            if wasAutomatic {
                try? store.set("automatic:\(next.key)", "true")
                sessions[next.key]?.automatic = true
            }
            if let slot = sessionOrder.firstIndex(of: id), !sessionOrder.contains(next.key) {
                sessionOrder[slot] = next.key
                if let json = try? JSONEncoder().encode(sessionOrder) { try? store.set("sessionOrder", String(decoding: json, as: UTF8.self)) }
            }
            refreshSessionGroupBadges()
            publish()
            let note = plan.dropped.isEmpty ? "" : " 다시 적용하지 않은 실행 인자: \(plan.dropped.joined(separator: " "))"
            let source = launchedConversation ? " 현재 대화 ID를 찾지 못해 처음 실행할 때의 대화 ID(\(conversation.prefix(8)))로 열었습니다." : ""
            var resumed = ""
            if resume {
                updateRestart(id, .confirming, "진행하던 작업을 이어가도록 입력하고 있습니다.", newSessionID: next.key)
                resumed = await resumeWorkAfterRestart(next.key, host: host)
                    ? " 진행하던 작업을 이어가도록 입력했습니다."
                    : " 진행하던 작업을 이어가라는 입력은 전달하지 못했습니다. 필요하면 터미널에서 직접 입력해주세요."
            }
            return updateRestart(id, .done, "같은 탭에서 같은 대화로 다시 시작했습니다." + resumed + source + note, newSessionID: next.key)
        }
        fail("다시 시작 명령은 입력했지만 새 CLI를 확인하지 못했습니다. 터미널을 확인해주세요.")
    }

    /// Types the resume line into a restarted session once its CLI accepts input. A dialog on the new screen
    /// (for example a choice about how to reopen a long conversation) is left for the user.
    private func resumeWorkAfterRestart(_ id: String, host: ScreenHost) async -> Bool {
        let until = Date().addingTimeInterval(restartResumeWait)
        var readySince: Date?
        while Date() < until, !Task.isCancelled, !remoteInputStopped {
            try? await Task.sleep(for: .milliseconds(500))
            guard let session = sessions[id], session.phase != .ended else { return false }
            var ready = session.phase == .idle
            if session.agent == .claude, let status = await claudeStatuses([session])[id] { ready = status == "idle" }
            if ready, session.pendingInTerminal || liveClaudeHooks.values.contains(where: { $0.request.sessionID == id }) { ready = false }
            guard ready else { readySince = nil; continue }
            // The registration appears before the input box does, so the idle state must hold for a moment.
            guard let since = readySince else { readySince = Date(); continue }
            guard Date().timeIntervalSince(since) >= restartResumeSettle else { continue }
            if let frame = try? await remoteTerminal(sessionID: id, realtime: true), frame.question != nil { return false }
            guard let current = sessions[id], current.phase != .ended else { return false }
            do { try await sendGroupLine(current, text: SessionRestartCommand.resumePrompt) } catch { return false }
            log(AuditEvent(sessionID: id, summary: "세션 다시 시작", outcome: "진행하던 작업 이어가기 입력", source: host.title,
                           context: AuditContext(session: current), request: SessionRestartCommand.resumePrompt))
            return true
        }
        return false
    }

    /// Recomputes which live sessions belong to saved groups. Reading conversation identities
    /// is too costly for every publication, so the result is cached until the next refresh.
    public func refreshSessionGroupBadges() {
        if groupBadgeTask != nil { groupBadgeRefreshPending = true; return }
        groupBadgeTask = Task { @MainActor [weak self] in
            repeat {
                guard let self, !Task.isCancelled else { return }
                self.groupBadgeRefreshPending = false
                let groups = (try? SessionGroupStore(directory: self.paths.directory).load()) ?? []
                var next: [String: SessionGroupBadge] = [:]
                if !groups.isEmpty, let live = try? await self.sessionGroupSessions() {
                    let refreshed = (try? SessionGroupStore(directory: self.paths.directory).load()) ?? groups
                    next = SessionGroupBadge.badges(groups: refreshed, live: live)
                }
                guard !Task.isCancelled else { return }
                self.groupBadgeRefreshedAt = Date()
                if next != self.sessionGroupBadges { self.sessionGroupBadges = next; self.publish() }
                if !self.groupBadgeRefreshPending { self.groupBadgeTask = nil; return }
            } while true
        }
    }

#if DEBUG
    /// Native previews show group rows without live conversation identities. Not in release builds.
    public func setSessionGroupBadgesForPreview(_ badges: [String: SessionGroupBadge]) {
        groupBadgeTask?.cancel(); groupBadgeTask = nil
        sessionGroupBadges = badges; groupBadgeRefreshedAt = Date(); publish()
    }
#endif

    /// Adds the cached group badge and the member's current task to a published row.
    private func projectSessionGroup(_ session: AgentSession) -> AgentSession {
        guard var badge = sessionGroupBadges[session.id] else {
            guard session.sessionGroup != nil else { return session }
            var value = session; value.sessionGroup = nil; return value
        }
        if let state = try? groupOrchestration() {
            switch state.current(groupID: badge.groupID, workerMemberID: badge.memberID) {
            case let item? where item.status == .working:
                badge.task = item.question.map { $0.isPermission ? .approval : .question } ?? .working
            case let item? where item.status == .completed: badge.task = .reporting
            default: badge.task = nil
            }
            badge.pendingReports = (state.undelivered + state.undeliveredQuestions)
                .filter { $0.groupID == badge.groupID && $0.parentMemberID == badge.memberID }.count
        }
        var value = session; value.sessionGroup = badge
        return value
    }

    /// A worker's first completion after its task becomes a report for the member that assigned it.
    private func receiveGroupTurn(conversation: String, turn: String, prompt: String, response: String?) {
        guard let id = SessionGroupMessage.terminalMessageID(prompt) else { return }
        do {
            let box = try groupMailbox()
            guard try box.confirmedPrompt(id, conversation: conversation, prompt: prompt),
                  let request = try box.message(id), request.deliversBody else { return }
            let state = try groupOrchestration()
            var resumedTask: UUID?
            var receipts: [UUID] = []
            try box.transaction {
                guard try box.claimTurn(id, turn: turn) else { return }
                try box.confirmDelivery(request)
                // An observed report or choice question counts as received, exactly like an ACK.
                if [.report, .choiceQuestion].contains(request.kind) { receipts.append(id) }
                let isReference = request.isReferencePrompt(prompt)
                let batch = isReference ? [] : try box.batchSources(request)
                for item in batch {
                    try box.confirmDelivery(item)
                    if [.report, .choiceQuestion].contains(item.kind) { receipts.append(item.id) }
                }
                if response == nil { try box.notePromptReceipt(id) }
                guard !isReference, let response, !response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !response.contains("\0") else { return }
                let resumed = try box.resumedWait(for: request)
                resumedTask = resumed?.decision == nil ? resumed?.task : nil
                let question: SessionGroupMessage
                if request.kind == .question, try box.canAutomaticallyAnswer(id) {
                    question = request
                } else if let upstream = resumed?.decision,
                          let original = try box.message(upstream), original.kind == .question,
                          original.groupID == request.groupID, original.recipientID == request.recipientID {
                    question = original
                } else { return }
                guard try box.message(sourceKey: "answer:" + question.id.uuidString) == nil else { return }
                _ = try box.answer(question.id, id: nil, group: question.groupID, sender: question.recipientID,
                                   recipient: question.senderID, text: response)
                try box.reconcileWaits(assignments: state.assignments, group: request.groupID)
            }
            if let resumedTask, let response,
               let assignment = state.assignments.first(where: { $0.id == resumedTask &&
                   $0.groupID == request.groupID && $0.workerMemberID == request.recipientID }) {
                noteGroupCompletion(assignment.workerSessionID, WorkCompletion(id: turn, summary: response),
                                    conversation: conversation, turn: turn, resumedTask: resumedTask)
            }
            if !receipts.isEmpty { try applyGroupMessageAcknowledgements(receipts) }
            refreshGroupWaits()
        } catch {
            // The provider retains the original response if the local store cannot commit it.
        }
    }

    private func noteGroupCompletion(_ sessionID: String, _ completion: WorkCompletion,
                                     conversation: String? = nil, prompt: String? = nil, turn: String? = nil,
                                     resumedTask: UUID? = nil) {
        guard var state = try? groupOrchestration(),
              let task = state.assignments.last(where: { $0.workerSessionID == sessionID && $0.status == .working && (resumedTask == nil || $0.id == resumedTask) && $0.sentAt <= completion.date.addingTimeInterval(1) }),
              let box = try? groupMailbox() else { return }
        do {
            if let expected = task.workerConversationID {
                guard expected.lowercased() == conversation?.lowercased(), let turn,
                      completion.originalResponse != nil else { return }
                if resumedTask == task.id {
                    guard try !box.taskStillWaiting(task.id) else { return }
                } else {
                    guard let prompt, try box.confirmedPrompt(task.id, conversation: expected, prompt: prompt),
                          try !box.tracksTask(task.id), try box.claimTurn(task.id, turn: turn) else { return }
                }
            } else if try box.tracksTask(task.id) { return }
            guard state.complete(id: task.id, completion: completion, preserveOriginal: task.workerConversationID != nil) != nil else { return }
            try saveGroupOrchestration(state)
        } catch { return }
        scheduleGroupDelivery()
    }

    private func scheduleGroupDelivery() {
        guard groupDeliveryTask == nil else { return }
        groupDeliveryTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if await !self.deliverGroupReports() { self.groupDeliveryTask = nil; return }
                try? await Task.sleep(for: .seconds(self.groupDeliveryInterval))
            }
        }
    }

    /// Persist reports and detected choice questions before notifying the parent. ACK completes delivery.
    private func deliverGroupReports() async -> Bool {
        guard (try? groupOrchestration())?.needsWatching == true else { return false }
        guard !remoteInputStopped else { return true }
        await recoverClaudeGroupCompletions()
        await watchGroupQuestions()
        guard let state = try? groupOrchestration() else { return false }
        let pending = state.undelivered.map({ ($0, false) }) + state.undeliveredQuestions.map({ ($0, true) })
        // This pass repeats every two seconds while a report waits for its
        // parent's ACK. Read the group file once per pass, and leave a report
        // already stored in the mailbox to the mailbox's own retry schedule.
        let groups = pending.isEmpty ? [] : (try? SessionGroupStore(directory: paths.directory).load())
        for (item, isQuestion) in pending {
            do {
                let source = isQuestion ? "question:\(item.id.uuidString):\(item.question!.id)" : "report:\(item.id.uuidString)"
                if let stored = try groupMailbox().message(sourceKey: source), stored.acknowledgedAt == nil,
                   stored.groupID == item.groupID, stored.senderID == item.workerMemberID, stored.recipientID == item.parentMemberID {
                    scheduleGroupMailboxDelivery()
                    continue
                }
                guard let group = groups?.first(where: { $0.id == item.groupID }),
                      group.members.contains(where: { $0.id == item.workerMemberID }),
                      group.members.contains(where: { $0.id == item.parentMemberID }) else { throw AppError.message("보고의 원래 그룹과 구성원을 확인하지 못해 보관하고 있습니다.") }
                let body = (isQuestion ? nil : item.originalResponse) ?? SessionGroupOrchestration.report(for: isQuestion ? [] : [item], questions: isQuestion ? [item] : [], titles: Dictionary(group.members.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first }))
                let message = try groupMailbox().enqueue(groupID: group.id, senderID: item.workerMemberID, recipientID: item.parentMemberID,
                    kind: isQuestion ? .choiceQuestion : .report, text: body, sourceKey: source,
                    originalReport: !isQuestion && item.originalResponse != nil)
                let box = try groupMailbox()
                if try box.acknowledgedBatchContains(message) { try box.confirmDelivery(message) }
                if try box.message(message.id)?.acknowledgedAt != nil { try applyGroupMessageAcknowledgements([message.id]) }
                else { scheduleGroupMailboxDelivery() }
            } catch {
                if var latest = try? groupOrchestration() { latest.noteDeliveryFailure([item.id], error.localizedDescription); try? saveGroupOrchestration(latest) }
            }
        }
        return (try? groupOrchestration())?.needsWatching ?? false
    }

    /// A missing Stop hook must not strand a delivered task forever. Only an
    /// idle, verified conversation's explicit final turn after this assignment
    /// can recover its report; an idle process alone is never completion proof.
    private func recoverClaudeGroupCompletions() async {
        guard let state = try? groupOrchestration() else { return }
        let working = state.assignments.filter {
            $0.status == .working && $0.isDelivered && sessions[$0.workerSessionID]?.agent == .claude && (try? groupMailbox().tracksTask($0.id)) == false
        }
        guard !working.isEmpty, let observed = try? await sessionGroupSessions(),
              let groups = try? SessionGroupStore(directory: paths.directory).load() else { return }
        let statuses = await claudeStatuses(observed.filter { live in working.contains { $0.workerSessionID == live.id } }.map(\.session))
        let reader = groupClaudeCompletionReader
        for item in working {
            guard !remoteInputStopped, !Task.isCancelled,
                  let member = groups.first(where: { $0.id == item.groupID })?.members.first(where: { $0.id == item.workerMemberID }),
                  let live = SessionGroupMatching.match(member, in: observed), live.id == item.workerSessionID,
                  statuses[live.id].map(ClaudeSessionRegistration.acceptsPrompt) == true, let current = sessions[live.id],
                  !current.pendingInTerminal, current.backgroundMonitoring != true,
                  current.interruption?.needsAttention != true,
                  ![.approval, .input, .ended].contains(current.phase),
                  let completion = await Task.detached(priority: .utility, operation: { reader(live, item.sentAt, item.task) }).value,
                  completion.date >= item.sentAt, completion.date <= Date().addingTimeInterval(5),
                  let latest = try? groupOrchestration().current(groupID: item.groupID, workerMemberID: item.workerMemberID),
                  latest.id == item.id, latest.status == .working else { continue }
            let evidence: String?
            if item.workerConversationID != nil, let promptAt = completion.originalPromptAt {
                evidence = try? groupMailbox().recoveryTurn(item.id, promptAt: promptAt, fallback: completion.id)
            } else {
                evidence = completion.id
            }
            noteGroupCompletion(item.workerSessionID, completion, conversation: live.conversationID,
                                prompt: SessionGroupOrchestration.taskMessage(item), turn: evidence)
        }
    }

    private func applyGroupMessageAcknowledgements(_ ids: [UUID]) throws {
        var state = try groupOrchestration(), reports: [UUID] = [], questions: [UUID] = []
        for id in ids {
            guard let message = try groupMailbox().message(id), message.acknowledgedAt != nil, let source = message.sourceKey else { continue }
            let fields = source.split(separator: ":", maxSplits: 2).map(String.init)
            guard fields.count >= 2, let assignmentID = UUID(uuidString: fields[1]) else { continue }
            if message.kind == .report { reports.append(assignmentID) }
            if message.kind == .choiceQuestion, fields.count == 3,
               state.assignments.first(where: { $0.id == assignmentID })?.question?.id == fields[2] { questions.append(assignmentID) }
        }
        guard !reports.isEmpty || !questions.isEmpty else { return }
        state.markReported(reports); state.markQuestionsReported(questions); try saveGroupOrchestration(state)
    }

    /// The caller must be the target's direct parent in a group with a leader, and the target must be live.
    private func verifyGroupDirection(_ groupID: UUID, caller: SessionGroupMember, target: SessionGroupMember) throws {
        guard let group = try SessionGroupStore(directory: paths.directory).load().first(where: { $0.id == groupID }),
              group.members.contains(caller), group.members.contains(target), group.canDirect(caller.id, worker: target.id),
              !groupClearActive(groupID) else {
            throw RemoteHTTPError(409, "구성원 연결 또는 지시 권한이 바뀌었습니다.", diagnostics: ["delivery": "not_started"])
        }
    }

    private func groupDirectWorker(_ object: JSONObject, groupID: UUID, memberID: UUID) async throws
        -> (group: SessionGroup, caller: SessionGroupLiveSession, callerMember: SessionGroupMember,
            target: SessionGroupMember, worker: SessionGroupLiveSession, current: AgentSession) {
        let observed = try await sessionGroupSessions()
        let (caller, _) = try sessionGroupCaller(object, observed: observed)
        guard let group = try SessionGroupStore(directory: paths.directory).load().first(where: { $0.id == groupID }) else {
            throw RemoteHTTPError(404, "그룹을 찾지 못했습니다. get_group_status로 현재 그룹을 확인해주세요.")
        }
        guard group.leaderMemberID != nil else { throw RemoteHTTPError(409, "이 그룹에는 그룹장이 없습니다. 관리 창의 세션 그룹에서 그룹장을 지정해주세요.") }
        guard let callerMember = group.members.first(where: { groupMemberIsCaller($0, caller: caller, observed: observed) }) else {
            throw RemoteHTTPError(403, "현재 세션은 이 그룹의 구성원으로 확인되지 않았습니다.")
        }
        guard let target = group.members.first(where: { $0.id == memberID }), group.canDirect(callerMember.id, worker: memberID) else {
            throw RemoteHTTPError(403, "직속 하위 구성원에게만 지시하거나 답할 수 있습니다. get_group_status의 canAssign을 확인해주세요.")
        }
        guard let worker = SessionGroupMatching.match(target, in: observed), let current = sessions[worker.id] else {
            throw RemoteHTTPError(409, "작업자 세션의 연결을 확인하지 못했습니다. get_session_groups의 canReconnect를 확인하고 reconnect_group_member로 재연결해주세요.")
        }
        return (group, caller, callerMember, target, worker, current)
    }

    /// Records a choice question that has kept a working worker waiting for the grace period.
    /// The grace leaves time for automatic answers, such as a yes/no confirmation, to happen first.
    private func watchGroupQuestions() async {
        guard let initial = try? groupOrchestration() else { return }
        let working = initial.assignments.filter { $0.status == .working }
        groupQuestionSeen = groupQuestionSeen.filter { id, _ in working.contains { $0.id == id } }
        var noted: [(UUID, GroupWorkerQuestion)] = [], cleared: [UUID] = []
        for item in working {
            guard let worker = sessions[item.workerSessionID], worker.phase == .input || worker.phase == .approval, !remoteInputStopped else {
                groupQuestionSeen[item.id] = nil
                if item.question != nil { cleared.append(item.id) }
                continue
            }
            guard let frame = try? await remoteTerminal(sessionID: worker.id, realtime: true) else { continue }
            let permission = worker.phase == .approval
            guard let question = permission ? delegablePermission(sessions[worker.id] ?? worker) : frame.question,
                  question.reply == nil, savedReply("terminalChoice:\(worker.id):\(question.id)") == nil,
                  !question.options.isEmpty else { continue }
            guard let seen = groupQuestionSeen[item.id], seen.id == question.id else {
                groupQuestionSeen[item.id] = (question.id, Date())
                continue
            }
            guard Date().timeIntervalSince(seen.since) >= groupQuestionGrace, item.question?.id != question.id else { continue }
            noted.append((item.id, GroupWorkerQuestion(id: question.id, text: question.question, options: question.options, permission: permission)))
        }
        guard !noted.isEmpty || !cleared.isEmpty, var state = try? groupOrchestration() else { return }
        cleared.forEach { state.clearQuestion($0) }
        for (id, question) in noted where state.noteQuestion(id, question) {
            if let item = state.assignments.first(where: { $0.id == id }) {
                log(AuditEvent(sessionID: item.workerSessionID, summary: "세션 그룹 작업 \(item.shortID)",
                               outcome: question.isPermission ? "그룹장 위임 승인 요청 대기" : "그룹 작업 질문 보고 대기",
                               source: "세션 그룹", tool: "group_question", request: question.text))
            }
        }
        try? saveGroupOrchestration(state)
    }

    /// A permission prompt the user delegated to the worker's parent. The global pause, macOS permission
    /// dialogs and system changes that AutoApprove never approves in the app stay with the user.
    private func delegablePermission(_ session: AgentSession) -> TerminalChoiceQuestion? {
        guard !snapshot.paused, !hasOSPermissionWait(session.id), systemSafetyStates[session.id]?.notice.isPending != true,
              let raw = remoteFrames[session.id]?.raw else { return nil }
        if let prompt = PromptDetector.detect(raw, agent: session.agent),
           Self.screenApprovalRisk(prompt, agent: session.agent, cwd: session.cwd) != nil { return nil }
        return TerminalChoiceQuestion.detectPermission(raw, agent: session.agent)
    }

    /// The status each Claude session registered for itself ("idle", "busy", "waiting", "shell", …).
    /// Sessions that are not Claude, or whose registration cannot be read, are left out.
    private func claudeStatuses(_ targets: [AgentSession]) async -> [String: String] {
        let claude = targets.filter { $0.agent == .claude && $0.phase != .ended }
        guard !claude.isEmpty else { return [:] }
        // Delivery checks one or two recipients, several times a second while it confirms a submission;
        // reading those processes alone avoids a system-wide process snapshot on every check.
        let reader = processReader, single = singleProcessReader, registry = claudeRegistryReader
        return await Task.detached(priority: .utility) {
            let records: [ProcessRecord]?
            if claude.count <= 4 {
                records = try? claude.flatMap { try single($0.pid) }
            } else {
                records = try? reader()
            }
            guard let records else { return [:] }
            var result: [String: String] = [:]
            for session in claude {
                guard let record = records.first(where: { $0.key == session.id && $0.agent == .claude }) else { continue }
                let directory = ProcessEnvironment.read(record)?["CLAUDE_CONFIG_DIR"]
                let rows = directory.map { ClaudeSessionRegistry.read(records: [record], directory: URL(fileURLWithPath: $0)) } ?? registry([record])
                if let status = rows.first(where: { $0.processID == record.key })?.status { result[session.id] = status }
            }
            return result
        }.value
    }

    /// Types one line of group traffic (a task, a report or a request) into a session and submits it.
    /// For Claude in a host that can type without focus, the line also reaches a background tab, and the
    /// change of Claude's status away from "idle" proves that it was submitted.
    private func sendGroupLine(_ session: AgentSession, text: String, preflight: (() async throws -> Void)? = nil) async throws {
        if session.agent == .agy {
            let conversation = agyEvents[session.id]?.conversationId
            _ = try await sendOriginalTerminalMessage(session, object: ["text": text, "revision": "session-group"], textOnly: true, backgroundOnly: true) { frame in
                try await preflight?()
                guard let state = self.agyEvents[session.id], state.conversationId == conversation, state.isIdle,
                      AgyComposerReadiness.isEmpty(frame.screen) else {
                    throw RemoteHTTPError(409, "agy의 현재 대화와 빈 입력창을 확인해주세요.", diagnostics: ["delivery":"not_started"])
                }
            }
            return
        }
        if session.agent == .claude, let host = ScreenHost(kind: session.terminal), screenConnections[host]?.enabled == true,
           let type = screenAdapters[host]?.typeLine, let before = await claudeStatuses([session])[session.id] {
            guard ClaudeSessionRegistration.acceptsPrompt(before) else {
                throw RemoteHTTPError(409, "대상 Claude가 대기 상태가 아니어서 입력하지 않았습니다. (상태: \(before))", diagnostics: ["delivery": "not_started"])
            }
            let reader = singleProcessReader, pid = session.pid
            guard let records = try? await Task.detached(operation: { try reader(pid) }).value,
                  let process = records.first(where: { $0.key == session.id && $0.agent == .claude && "/dev/" + $0.tty == session.tty && $0.isForeground }),
                  sendingMessages.insert(session.id).inserted else {
                throw RemoteHTTPError(409, "대상 CLI를 확인하지 못해 입력하지 않았습니다.", diagnostics: ["delivery": "not_started"])
            }
            defer { sendingMessages.remove(session.id) }
            let target = ScreenTarget(tty: session.tty, handle: session.screenHandle, jobPIDs: [process.pid], sourcePID: process.pid, sourceStarted: process.started)
            try await preflight?()
            guard try await Task.detached(operation: { try type(target, text) }).value == .sent else {
                throw RemoteHTTPError(409, "대상 터미널 탭을 찾지 못해 입력하지 않았습니다.", diagnostics: ["delivery": "not_started"])
            }
            func submitted(within seconds: Double) async -> Bool {
                let until = Date().addingTimeInterval(seconds)
                while Date() < until {
                    try? await Task.sleep(for: .milliseconds(300))
                    if let status = await claudeStatuses([session])[session.id], !ClaudeSessionRegistration.acceptsPrompt(status) { return true }
                }
                return false
            }
            if await submitted(within: 1.5) { return }
            // A long line arrives as a paste, and Claude does not take the newline at its end as Enter.
            _ = try? await Task.detached(operation: { try type(target, "") }).value
            if await submitted(within: 6) { return }
            throw RemoteHTTPError(409, "터미널에 입력했지만 제출을 확인하지 못했습니다. 대상 터미널의 입력창을 확인해주세요.", diagnostics: ["delivery": "unknown"])
        }
        _ = try await sendOriginalTerminalMessage(session, object: ["text": text, "revision": "session-group"], textOnly: true, backgroundOnly: true, preflight: { _ in
            try await preflight?()
        })
    }

    /// Turns on automatic approval for a group worker. The global pause stays
    /// the user's decision and is reported rather than overridden.
    private func enableGroupWorkerApproval(_ id: String) -> GroupWorkerApproval {
        var changed = false
        if sessions[id]?.automatic != true {
            do { try setAutomatic(id, enabled: true); changed = true } catch { return .unavailable }
        }
        if snapshot.paused { return changed ? .enabledWhilePaused : .paused }
        return changed ? .enabled : .already
    }

    private func groupTaskJSON(_ assignment: SessionGroupAssignment?) -> Any {
        guard let assignment else { return NSNull() }
        let formatter = ISO8601DateFormatter()
        return ["id": assignment.id.uuidString, "status": assignment.status.rawValue, "task": assignment.task,
                "sentAt": formatter.string(from: assignment.sentAt), "delivered": assignment.isDelivered,
                "completedAt": assignment.completedAt.map(formatter.string(from:)) as Any? ?? NSNull(),
                "summary": assignment.summary as Any? ?? NSNull(),
                "question": assignment.question.map { question -> JSONObject in
                    ["text": question.text, "options": question.options,
                     "seenAt": formatter.string(from: question.seenAt)]
                } as Any? ?? NSNull(),
                "deliveryError": assignment.deliveryError as Any? ?? NSNull()] as JSONObject
    }

    private func loadGroupClears() throws -> [SessionGroupClearOperation] {
        if let groupClearOperations { return groupClearOperations }
        let values: [SessionGroupClearOperation]
        if let saved = store.value("sessionGroupClearOperations") {
            guard let bytes = saved.data(using: .utf8), let decoded = try? JSONDecoder().decode([SessionGroupClearOperation].self, from: bytes), decoded.count <= 40 else { throw AppError.message("그룹 초기화 기록을 읽지 못했습니다. 기존 기록은 유지합니다.") }
            values = decoded
        } else { values = [] }
        groupClearOperations = values; return values
    }
    private func saveGroupClears(_ values: [SessionGroupClearOperation]) throws {
        try store.set("sessionGroupClearOperations", String(decoding: JSONEncoder().encode(values), as: UTF8.self))
        groupClearOperations = values
    }
    private func groupClearActive(_ id: UUID) -> Bool { (try? loadGroupClears().contains { $0.groupID == id && !$0.done }) == true }
    private func saveGroupClearTarget(_ request: UUID, _ target: SessionGroupClearTarget) throws {
        var values = try loadGroupClears()
        guard let ji = values.firstIndex(where: { $0.id == request }), let ti = values[ji].targets.firstIndex(where: { $0.memberID == target.memberID }) else { throw AppError.message("초기화 요청이 바뀌었습니다.") }
        if values[ji].targets[ti] == target { return }
        values[ji].targets[ti] = target; try saveGroupClears(values)
    }
    private func scheduleGroupClears() {
        // An empty inventory on startup does not establish that the original
        // processes exited. Resume only after a successful discovery snapshot.
        guard groupClearDiscoveryReady, groupClearTask == nil, !remoteInputStopped else { return }
        groupClearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            while !Task.isCancelled, let self, !self.remoteInputStopped {
                guard let jobs = try? self.loadGroupClears(), jobs.contains(where: { !$0.done }) else { self.groupClearTask = nil; return }
                if !self.snapshot.paused {
                    for job in jobs where !job.done {
                        for target in job.targets where !target.terminal {
                            guard !Task.isCancelled, !self.remoteInputStopped else { return }
                            await self.advanceGroupClear(job, target: target)
                        }
                    }
                }
                try? await Task.sleep(for: .seconds(self.groupClearInterval))
            }
        }
    }
    private func clearFrameReady(_ raw: String, agent: AgentKind) -> Bool {
        guard !RemoteMessageReadiness.hasMenu(raw, agent: agent), ActivityDetector.detect(raw, agent: agent).phase != .working else { return false }
        return agent == .codex ? CodexProgressScreen.ready(raw) : agent == .agy ? AgyComposerReadiness.isEmpty(raw) : ClaudeComposerReadiness.isEmpty(raw)
    }
    private func advanceGroupClear(_ job: SessionGroupClearOperation, target initial: SessionGroupClearTarget) async {
        var target = initial
        do {
            if target.memberID == job.callerMemberID, let current = try loadGroupClears().first(where: { $0.id == job.id }),
               current.targets.contains(where: { $0.memberID != job.callerMemberID && !$0.terminal }) { return }
            guard let current = sessions[target.runtimeID], current.pid == target.pid, current.started == target.started,
                  current.tty == target.tty, current.cwd == target.cwd, current.agent.rawValue == target.agent, current.phase != .ended else {
                target.phase = "failed"; target.detail = "원래 터미널이 종료되거나 교체되어 초기화하지 않았습니다."; try saveGroupClearTarget(job.id, target); return
            }
            guard let group = try SessionGroupStore(directory: paths.directory).load().first(where: { $0.id == job.groupID }),
                  let member = group.members.first(where: { $0.id == target.memberID }), member.agent == current.agent,
                  target.phase != "waiting" || group.leaderMemberID == nil || group.isLeader(job.callerMemberID),
                  member.runtimeID == nil || member.runtimeID == current.id, member.providerHome == nil || target.providerHome == nil || member.providerHome == target.providerHome else {
                target.phase = "failed"; target.detail = "그룹 소속이나 원래 연결이 바뀌었습니다."; try saveGroupClearTarget(job.id, target); return
            }
            guard !(await userInputHasPriority(current.id,backgroundOnly:true)), !snapshot.paused, !automaticInputBusy(current.id), !current.pendingInTerminal,
                  ![.approval, .ended].contains(current.phase), !sendingMessages.contains(current.id), !groupStatusQueries.contains(current.id) else { return }
            let frame = try await remoteTerminal(sessionID: current.id, realtime: true, textOnly: true)
            guard clearFrameReady(frame.screen, agent: current.agent) else {
                target.detail = "작업·작성 중인 입력·질문이 끝나고 빈 입력창이 될 때까지 기다립니다."; try saveGroupClearTarget(job.id, target); return
            }
            if target.phase == "waiting" {
                if target.verifiedAt.map({ Date().timeIntervalSince($0) > 10 }) ?? true {
                    let id: String
                    if current.agent == .claude || current.agent == .agy, let live = try await sessionGroupSessions().first(where: { $0.id == current.id }), let fresh = live.conversationID { id = fresh }
                    else { id = try await statusConversationID(current,backgroundOnly:true) }
                    target.beforeID = id; target.verifiedAt = Date(); target.identityAttempts = 0; try saveGroupClearTarget(job.id, target)
                    if current.agent == .codex { try await waitForGroupStatusInput(current,backgroundOnly:true) }
                }
                // Commit before the write. Recovery only queries identity;
                // uncertain writes can never cause an automatic second /clear.
                target.phase = "issued"; target.detail = "초기화 전달 후 새 세션 ID를 확인합니다."; try saveGroupClearTarget(job.id, target)
                do {
                    _ = try await sendOriginalTerminalMessage(current, object: ["text": current.agent == .agy ? "/new" : "/clear", "revision": frame.revision], textOnly: true, backgroundOnly: true, preflight: { _ in
                        let latest = try await self.remoteTerminal(sessionID: current.id, realtime: true, textOnly: true)
                        let userPriority=await self.userInputHasPriority(current.id,backgroundOnly:true)
                        let latestGroup = try SessionGroupStore(directory: self.paths.directory).load().first { $0.id == job.groupID }
                        guard let latestGroup, latestGroup.leaderMemberID == nil || latestGroup.isLeader(job.callerMemberID),
                              let latestMember = latestGroup.members.first(where: { $0.id == target.memberID }),
                              latestMember.runtimeID == nil || latestMember.runtimeID == current.id,
                              latestMember.agent == current.agent,
                              [target.savedID, target.beforeID].contains(where: { UUID(uuidString: $0) == UUID(uuidString: latestMember.conversationID) }) else {
                            throw RemoteHTTPError(409, "그룹 소속이나 초기화 권한이 바뀌어 입력하지 않았습니다.", diagnostics: ["delivery": "not_started"])
                        }
                        let reason = self.snapshot.paused ? "AutoApprove가 일시정지되었습니다." :
                            userPriority ? "대상 세션의 사용자 입력 우선권을 기다립니다." :
                            self.automaticInputBusy(current.id) ? "대상 세션의 자동 입력 완료를 기다립니다." :
                            !self.clearFrameReady(latest.screen,agent:current.agent) ? "대상 화면에서 빈 입력창을 확인하지 못했습니다." : nil
                        if let reason {throw RemoteHTTPError(409,reason,diagnostics:["delivery":"not_started"])}
                    })
                    groupStatusIdentities.removeValue(forKey: current.id)
                    discardGroupMCPIdentities(for: current.id)
                } catch {
                    if (error as? RemoteHTTPError)?.diagnostics?["delivery"] == "not_started" { target.phase = "waiting" }
                    else {
                        groupStatusIdentities.removeValue(forKey: current.id)
                        discardGroupMCPIdentities(for: current.id)
                    }
                    target.detail = error.localizedDescription; try saveGroupClearTarget(job.id, target); return
                }
            }
            guard !Task.isCancelled, !remoteInputStopped else { return }
            let newID: String?
            if current.agent == .claude || current.agent == .agy { newID = try await sessionGroupSessions().first(where: { $0.id == current.id })?.conversationID }
            else { newID = try await statusConversationID(current,backgroundOnly:true) }
            guard let newID, UUID(uuidString: newID) != nil, UUID(uuidString: newID) != UUID(uuidString: target.beforeID) else {
                target.identityAttempts += 1
                if target.identityAttempts >= 3 { target.phase = "needs_review"; target.detail = "새 ID를 확인하지 못했습니다. /clear는 다시 보내지 않습니다. 원래 터미널에서 세션 ID를 갱신해주세요." }
                try saveGroupClearTarget(job.id, target); return
            }
            guard !Task.isCancelled, !remoteInputStopped, let latest = sessions[current.id], latest.pid == target.pid, latest.started == target.started, latest.tty == target.tty else { return }
            let groupStore = SessionGroupStore(directory: paths.directory), saved = try groupStore.load()
            guard let latestMember = saved.first(where: { $0.id == job.groupID })?.members.first(where: { $0.id == target.memberID }),
                  latestMember.runtimeID == nil || latestMember.runtimeID == target.runtimeID,
                  [target.savedID, target.beforeID, newID].contains(where: { UUID(uuidString: $0) == UUID(uuidString: latestMember.conversationID) }) else { throw AppError.message("ID 확인 중 그룹 연결이 바뀌어 덮어쓰지 않았습니다.") }
            var updated = saved
            for gi in updated.indices {
                for mi in updated[gi].members.indices {
                    let value = updated[gi].members[mi]
                    guard value.agent == current.agent, value.runtimeID == target.runtimeID || (value.id == target.memberID && updated[gi].id == job.groupID),
                          value.providerHome == nil || target.providerHome == nil || value.providerHome == target.providerHome,
                          (value.id == target.memberID && updated[gi].id == job.groupID) || UUID(uuidString: value.conversationID) == UUID(uuidString: target.beforeID) else { continue }
                    updated[gi].members[mi].conversationID = newID
                    updated[gi].members[mi].runtimeID = target.runtimeID
                }
            }
            try groupStore.save(updated, expected: saved)
            groupStatusIdentities[current.id] = GroupStatusIdentity(session: current, conversationID: newID, home: target.providerHome,
                                                                   contradictedRollout: UUID(uuidString: target.beforeID))
            var state = try groupOrchestration(); state.supersede(groupID: job.groupID, workerMemberID: target.memberID); try saveGroupOrchestration(state)
            target.afterID = newID; target.phase = "completed"; target.detail = "초기화와 새 세션 ID 갱신을 확인했습니다."
            try saveGroupClearTarget(job.id, target); refreshSessionGroupBadges(); scheduleGroupMailboxDelivery()
        } catch {
            target.identityAttempts += 1
            if target.identityAttempts >= 3 { target.phase = target.phase == "issued" ? "needs_review" : "failed" }
            target.detail = error.localizedDescription; try? saveGroupClearTarget(job.id, target)
        }
    }
    private func groupModelSettings(_ groups: [SessionGroup], observed: [SessionGroupLiveSession]) async -> [String: SessionGroupModelSettings] {
        let targets = groups.flatMap(\.members).compactMap { SessionGroupMatching.match($0, in: observed) }
        let reader = groupModelSettingsReader
        return await Task.detached(priority: .utility) {
            var result: [String: SessionGroupModelSettings] = [:]
            for live in targets where result[live.id] == nil {
                guard live.conversationID.flatMap(UUID.init(uuidString:)) != nil else { continue }
                result[live.id] = reader(live)
            }
            return result
        }.value
    }

    public func mcpAction(_ object: JSONObject) async throws -> JSONObject {
        guard let owner = object["owner"] as? String, UUID(uuidString: owner) != nil,
              let tool = object["tool"] as? String else { throw RemoteHTTPError(400, "MCP 연결 정보가 필요합니다.") }
        observeGroupMCPIdentity(object, owner: owner)
        func encoded<T: Encodable>(_ value: T) throws -> Any {
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            return try JSONSerialization.jsonObject(with: encoder.encode(value))
        }
        func urls(_ fragment: String) -> [String] { webStatus.directURLs.map { $0 + "/#" + fragment } }
        switch tool {
        case "set_group_member_title", "set_group_member_tab_color":
            guard let groupID = (object["groupID"] as? String).flatMap(UUID.init(uuidString:)),
                  let memberID = (object["memberID"] as? String).flatMap(UUID.init(uuidString:)) else { throw RemoteHTTPError(400, "groupID와 memberID(UUID)를 지정해주세요.") }
            let observed = try await sessionGroupSessions()
            let (caller, _) = try sessionGroupCaller(object, observed: observed)
            guard let group = try SessionGroupStore(directory: paths.directory).load().first(where: { $0.id == groupID }),
                  let callerMember = group.members.first(where: { groupMemberIsCaller($0, caller: caller, observed: observed) }) else { throw RemoteHTTPError(403, "현재 세션이 속한 그룹만 변경할 수 있습니다.") }
            guard group.leaderMemberID == nil || group.isLeader(callerMember.id) else { throw RemoteHTTPError(403, "그룹의 탭 표시 변경은 그룹장만 요청할 수 있습니다.") }
            guard !groupClearActive(groupID) else { throw RemoteHTTPError(409, "그룹 초기화가 끝난 뒤 탭 표시를 변경해주세요.") }
            guard let member = group.members.first(where: { $0.id == memberID }) else { throw RemoteHTTPError(404, "이 그룹에서 지정한 구성원을 찾지 못했습니다.") }
            guard let live = SessionGroupMatching.match(member, in: observed), let session = sessions[live.id], session.phase != .ended else { throw RemoteHTTPError(409, "대화 ID와 원래 터미널 연결을 확인한 뒤 다시 시도해주세요.") }
            guard let host = ScreenHost(kind: session.terminal), let write = screenAdapters[host]?.setTabLabel else { throw RemoteHTTPError(501, "탭 이름·색상 표식 변경은 Terminal과 iTerm2에서 지원합니다.") }
            var customization = session.customization ?? .init()
            let title: String
            var role: String?
            if tool == "set_group_member_title" {
                guard let value = object["title"] as? String else { throw RemoteHTTPError(400, "새 탭 이름 title을 지정해주세요.") }
                title = value
                if let value = object["role"] as? String {
                    let line = SessionGroupOrchestration.oneLine(value).trimmingCharacters(in: .whitespaces)
                    guard (1...120).contains(line.count) else { throw RemoteHTTPError(400, "role은 한 줄로 1~120자로 적어주세요.") }
                    role = line
                }
            } else {
                guard let color = object["color"] as? String, color == "default" || SessionColor(rawValue: color) != nil else { throw RemoteHTTPError(400, "탭 색상을 지정해주세요. red·orange·yellow·green·blue·purple·gray·default를 지원합니다.") }
                title = customization.title.isEmpty ? TerminalTabLabel.baseTitle(session.terminalTitle ?? member.title) : customization.title
                customization.color = color == "default" ? nil : SessionColor(rawValue: color)
            }
            let label = try TerminalTabLabel(title: title, color: customization.color?.rawValue).validated()
            guard tabLabelChanges.insert(session.id).inserted else { throw RemoteHTTPError(409, "이 세션의 탭 표시를 변경 중입니다. 잠시 뒤 다시 시도해주세요.") }
            defer { tabLabelChanges.remove(session.id) }
            let validate = nativeIdentity(session)
            let target = ScreenTarget(tty: session.tty, handle: session.screenHandle, jobPIDs: [session.pid], sourcePID: session.pid, sourceStarted: session.started)
            let actual = try await Task.detached(priority: .utility) {
                guard try validate() else { throw AppError.message("원래 터미널 프로세스가 바뀌어 표시를 변경하지 않았습니다.") }
                let actual = try write(target, label)
                guard try validate(), actual == label.rendered else { throw AppError.message("원래 세션에 적용된 탭 이름을 확인하지 못했습니다.") }
                return actual
            }.value
            guard let current = sessions[session.id], current.pid == session.pid, current.started == session.started, current.phase != .ended else { throw RemoteHTTPError(409, "탭 변경 중 세션이 종료되거나 교체되었습니다.") }
            customization.title = label.title
            do { try setCustomization(session.id, value: customization) }
            catch { throw RemoteHTTPError(500, "원래 탭 이름은 변경했지만 표시 설정을 저장하지 못했습니다. " + error.localizedDescription, diagnostics: ["nativeApplied": "true"]) }
            if let role {
                do { try setGroupMemberRole(groupID: groupID, memberID: memberID, role: role) }
                catch { throw RemoteHTTPError(500, "탭 이름은 변경했지만 역할을 저장하지 못했습니다. " + error.localizedDescription, diagnostics: ["nativeApplied": "true"]) }
            }
            return ["groupID": groupID.uuidString, "memberID": memberID.uuidString, "conversationID": live.conversationID as Any? ?? NSNull(),
                    "applied": true, "verified": true, "title": label.title, "role": role as Any? ?? NSNull(), "tabTitle": actual,
                    "color": label.color as Any? ?? NSNull(), "colorMode": "title_marker", "transport": "local_terminal", "networkRequired": false]
        case "clear_session_group", "clear_group_member", "get_group_clear_status":
            guard let groupID = (object["groupID"] as? String).flatMap(UUID.init(uuidString:)) else { throw RemoteHTTPError(400, "groupID를 지정해주세요.") }
            let suppliedRequest = (object["requestID"] as? String).flatMap(UUID.init(uuidString:))
            guard (object["requestID"] == nil || suppliedRequest != nil), tool == "get_group_clear_status" || suppliedRequest != nil else { throw RemoteHTTPError(400, "새 초기화에는 재시도에도 유지할 requestID(UUID)를 지정해주세요.") }
            let selectedMemberID: UUID?
            if tool == "clear_group_member" {
                guard let id = (object["memberID"] as? String).flatMap(UUID.init(uuidString:)) else { throw RemoteHTTPError(400, "초기화할 memberID(UUID)를 지정해주세요.") }
                selectedMemberID = id
            } else { selectedMemberID = nil }
            let observed = try await sessionGroupSessions()
            let (caller, _) = try sessionGroupCaller(object, observed: observed)
            guard let group = try SessionGroupStore(directory: paths.directory).load().first(where: { $0.id == groupID }),
                  let callerMember = group.members.first(where: { groupMemberIsCaller($0, caller: caller, observed: observed) }) else { throw RemoteHTTPError(403, "현재 세션이 속한 그룹만 조회하거나 초기화할 수 있습니다.") }
            var jobs = try loadGroupClears()
            if tool == "get_group_clear_status" {
                guard let previous = jobs.last(where: { $0.groupID == groupID && (suppliedRequest == nil || suppliedRequest == $0.id) }) else { throw RemoteHTTPError(404, "초기화 요청을 찾지 못했습니다.") }
                return previous.json
            }
            let request = suppliedRequest!
            if let previous = jobs.first(where: { $0.id == request }) {
                guard previous.groupID == groupID else { throw RemoteHTTPError(409, "다른 그룹에서 사용한 requestID입니다.") }
                guard previous.selectedMemberID == selectedMemberID else { throw RemoteHTTPError(409, "다른 초기화 대상에 사용한 requestID입니다. 대상이 다른 새 요청에는 새 requestID를 사용해주세요.") }
                return previous.json
            }
            guard group.leaderMemberID == nil || group.isLeader(callerMember.id) else { throw RemoteHTTPError(403, "그룹 초기화는 그룹장만 요청할 수 있습니다.") }
            guard !groupClearActive(groupID) else { throw RemoteHTTPError(409, "이 그룹의 초기화가 진행 중입니다. 기존 requestID로 상태를 확인해주세요.") }
            jobs.removeAll { $0.done && Date().timeIntervalSince($0.createdAt) > 604800 }
            if jobs.count >= 40 { jobs.removeAll { $0.done } }
            guard jobs.count < 40 else { throw RemoteHTTPError(409, "진행 중인 그룹 초기화 요청이 너무 많습니다.") }
            let members: [SessionGroupMember]
            if let selectedMemberID {
                guard let member = group.members.first(where: { $0.id == selectedMemberID }) else { throw RemoteHTTPError(404, "이 그룹에서 지정한 구성원을 찾지 못했습니다.") }
                members = [member]
            } else { members = group.members.filter { $0.id != callerMember.id } + [callerMember] }
            let job = SessionGroupClearOperation(id: request, groupID: groupID, callerMemberID: callerMember.id,
                targets: members.map { SessionGroupClearTarget(member: $0, live: SessionGroupMatching.connection($0, in: observed)) }, selectedMemberID: selectedMemberID)
            jobs.append(job); try saveGroupClears(jobs); scheduleGroupClears()
            var result = job.json; result["accepted"] = true
            result["message"] = selectedMemberID == nil
                ? "초기화를 저장했습니다. 호출자 자신을 포함한 전체 구성원의 빈 입력창에서 /clear를 한 번씩 실행하고 새 ID를 확인합니다. 작업 중이면 기다립니다. 같은 requestID로 get_group_clear_status를 조회하세요. 접수는 초기화 완료가 아닙니다."
                : "지정한 구성원의 초기화를 저장했습니다. 해당 세션의 빈 입력창에서 /clear를 한 번 실행하고 새 ID를 확인합니다. 작업 중이면 기다립니다. 같은 requestID로 get_group_clear_status를 조회하세요. 자신을 지정했다면 현재 응답을 마쳐 초기화될 수 있게 하세요. 접수는 초기화 완료가 아닙니다."
            return result
        case "reconnect_group_member", "send_group_message", "ask_group_question", "reply_group_question":
            guard let groupID = (object["groupID"] as? String).flatMap(UUID.init(uuidString:)),
                  let memberID = (object["memberID"] as? String).flatMap(UUID.init(uuidString:)) else {
                throw RemoteHTTPError(400, "그룹 ID와 구성원 ID를 지정해주세요.")
            }
            if tool == "reconnect_group_member" { return try await reconnectGroupMember(object, groupID: groupID, memberID: memberID) }
            guard let text = object["text"] as? String else { throw RemoteHTTPError(400, "메시지 내용을 지정해주세요.") }
            return try await enqueueGroupMessage(object, groupID: groupID, memberID: memberID, text: text,
                kind: tool == "ask_group_question" ? .question : tool == "reply_group_question" ? .reply : .message)
        case "wait_group_dependencies", "update_group_wait", "complete_group_task":
            return try await groupWaitAction(tool, object: object)
        case "get_group_messages", "ack_group_messages":
            guard let groupID = (object["groupID"] as? String).flatMap(UUID.init(uuidString:)) else { throw RemoteHTTPError(400, "그룹 ID를 지정해주세요.") }
            let (_, caller) = try await groupMailboxCaller(object, groupID: groupID)
            if tool == "ack_group_messages" {
                guard let strings = object["messageIDs"] as? [String] else { throw RemoteHTTPError(400, "수신 확인할 messageIDs를 지정해주세요.") }
                let ids = strings.compactMap(UUID.init(uuidString:))
                guard ids.count == strings.count else { throw RemoteHTTPError(400, "메시지 ID는 UUID여야 합니다.") }
                try groupMailbox().acknowledge(ids, groupID: groupID, recipientID: caller.id)
                try applyGroupMessageAcknowledgements(ids)
                scheduleGroupMailboxDelivery()
                return ["acknowledged": true, "messageIDs": strings, "message": "수신 확인을 저장했습니다. 작업 수행·동의·승인을 의미하지 않습니다."]
            }
            func integer(_ name: String, fallback: Int64) throws -> Int64 {
                guard let raw = object[name] else { return fallback }
                guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                      number.doubleValue.isFinite, number.doubleValue >= 0, number.doubleValue < Double(Int64.max),
                      number.doubleValue == Double(number.int64Value) else { throw RemoteHTTPError(400, "조회 페이지는 음수가 아닌 정수로 지정해주세요.") }
                return number.int64Value
            }
            let after = try integer("afterSequence", fallback: 0), limit = Int(try integer("limit", fallback: 50))
            let direction = object["direction"] as? String ?? "inbox"
            guard (1...50).contains(limit), ["inbox", "outbox"].contains(direction),
                  object["direction"] == nil || object["direction"] is String,
                  object["includeAcknowledged"] == nil || (object["includeAcknowledged"] as? NSNumber).map({ CFGetTypeID($0) == CFBooleanGetTypeID() }) == true else { throw RemoteHTTPError(400, "조회 방향·페이지 범위를 확인해주세요.") }
            if let id = try GroupWaitRequest.uuid(object, "messageID") {
                guard let message = try groupMailbox().message(id), message.groupID == groupID,
                      (direction == "outbox" ? message.senderID : message.recipientID) == caller.id else { throw RemoteHTTPError(404, "자기 수신함·발신함에 해당 메시지가 없습니다.") }
                return ["messages": [message.json], "hasMore": false, "direction": direction, "groupID": groupID.uuidString]
            }
            let messages = try groupMailbox().list(groupID: groupID, memberID: caller.id, outbox: direction == "outbox",
                includeAcknowledged: object["includeAcknowledged"] as? Bool == true, after: after, limit: limit + 1)
            let page = Array(messages.prefix(limit))
            return ["groupID": groupID.uuidString, "memberID": caller.id.uuidString, "messages": page.map(\.json),
                    "hasMore": messages.count > limit, "nextAfterSequence": page.last?.sequence as Any? ?? NSNull(),
                    "networkRequired": false, "transport": "local_mailbox",
                    "message": "조회만으로 수신 완료 처리하지 않습니다. 받은 messageID를 ack_group_messages로 확인하세요. 처리한 ID는 재실행하지 마세요. 질문은 reply_group_question으로 보낸 구성원에게 답하세요."]
        case "get_session_groups":
            let observed = try await sessionGroupSessions()
            let (caller, attribution) = try sessionGroupCaller(object, observed: observed, recovery: true)
            let groups = try SessionGroupStore(directory: paths.directory).load()
            let matching = groups.filter { group in group.members.contains { groupRecoveryCaller($0, caller: caller, observed: observed) } }
            let modelSettings = await groupModelSettings(matching, observed: observed)
            let output: [JSONObject] = matching.map { group in
                let callerMember = group.members.first { groupRecoveryCaller($0, caller: caller, observed: observed) }!
                let members: [JSONObject] = group.members.map { member in
                    let live = SessionGroupMatching.match(member, in: observed)
                    let unresolved = live == nil ? SessionGroupMatching.connection(member, in: observed) : nil
                    return ["id": member.id.uuidString, "agent": member.agent.rawValue, "title": member.title, "role": member.role as Any? ?? NSNull(),
                            "cwd": member.cwd, "conversationID": member.conversationID,
                            "providerHome": member.providerHome as Any? ?? NSNull(), "connected": live != nil,
                            "connectionState": live != nil ? "verified" : SessionGroupMatching.connection(member, in: observed) != nil ? "identity_unverified" : "disconnected",
                            "reconnectBlockedReason": unresolved.flatMap { $0.session.agent == .codex ? Self.missingCodexGroupIdentity : nil } as Any? ?? NSNull(),
                            "messagingName": live?.messagingName as Any? ?? NSNull(),
                            "model": live.flatMap { agyEvents[$0.id]?.modelName ?? modelSettings[$0.id]?.model } as Any? ?? NSNull(),
                            "reasoningEffort": live.flatMap { modelSettings[$0.id]?.reasoningEffort } as Any? ?? NSNull(),
                            "modelSettingsSource": live.flatMap { modelSettings[$0.id]?.source } as Any? ?? NSNull(),
                            "modelSettingsRecordedAt": live.flatMap { modelSettings[$0.id]?.recordedAt }.map { ISO8601DateFormatter().string(from: $0) } as Any? ?? NSNull(),
                            "isCaller": member.id == callerMember.id, "sameAgent": member.agent == caller.session.agent,
                            "canAskQuestion": member.id != callerMember.id && live?.conversationID.flatMap(UUID.init(uuidString:)) != nil && UUID(uuidString: callerMember.conversationID) != nil && groupMemberIsCaller(callerMember, caller: caller, observed: observed),
                            "canReconnect": canReconnectGroupMember(member, group: group, caller: caller, callerMember: callerMember, observed: observed),
                            "isLeader": group.isLeader(member.id),
                            "parentMemberID": group.parentID(of: member.id)?.uuidString as Any? ?? NSNull()]
                }
                return ["id": group.id.uuidString, "name": group.name, "members": members,
                        "leaderMemberIDs": group.leaderMemberIDs.map(\.uuidString),
                        "leaderMemberID": group.leaderMemberID?.uuidString as Any? ?? NSNull()]
            }
            return ["groups": output, "agent": caller.session.agent.rawValue, "attribution": attribution,
                    "transport": "local_terminal", "networkRequired": false,
                    "message": "그룹 통신은 같은 Mac의 Unix 소켓과 원래 터미널만 사용합니다. 연결이 끊겼고 canReconnect가 true이면 reconnect_group_member로 재연결하세요. 자유 형식 질문·답변은 ask_group_question과 reply_group_question으로 Codex↔Claude를 포함한 같은 그룹 구성원에게 전달하세요. 그룹 상태는 get_group_status, 직속 작업·승인 지시는 assign_group_task·answer_group_question을 사용하세요. 일반 대화는 send_group_message로 Codex↔Claude를 포함한 같은 그룹 구성원에게 전달하세요. 외부 서버나 각 도구의 별도 메시지 경로로 우회하지 마세요."]
        case "get_group_status":
            let observed = try await sessionGroupSessions()
            let (caller, attribution) = try sessionGroupCaller(object, observed: observed)
            let groups = try SessionGroupStore(directory: paths.directory).load()
            let state = try groupOrchestration()
            let visibleGroups = groups.filter { $0.members.contains { groupMemberIsCaller($0, caller: caller, observed: observed) } }
            let modelSettings = await groupModelSettings(visibleGroups, observed: observed)
            let memberStatuses = await claudeStatuses(observed.map(\.session))
            let includeGraph = try GroupWaitRequest.flag(object, "includeWaitGraph")
            let output: [JSONObject] = try groups.compactMap { group in
                guard let callerMember = group.members.first(where: { groupMemberIsCaller($0, caller: caller, observed: observed) }) else { return nil }
                let members: [JSONObject] = group.treeOrder.map { entry in
                    let member = entry.member, live = SessionGroupMatching.match(member, in: observed)
                    let phase = live.flatMap { sessions[$0.id]?.phase }
                    return ["id": member.id.uuidString, "agent": member.agent.rawValue, "title": member.title, "role": member.role as Any? ?? NSNull(), "cwd": member.cwd,
                            "claudeStatus": live.flatMap { memberStatuses[$0.id] } as Any? ?? NSNull(),
                            "model": live.flatMap { agyEvents[$0.id]?.modelName ?? modelSettings[$0.id]?.model } as Any? ?? NSNull(),
                            "reasoningEffort": live.flatMap { modelSettings[$0.id]?.reasoningEffort } as Any? ?? NSNull(),
                            "modelSettingsSource": live.flatMap { modelSettings[$0.id]?.source } as Any? ?? NSNull(),
                            "modelSettingsRecordedAt": live.flatMap { modelSettings[$0.id]?.recordedAt }.map { ISO8601DateFormatter().string(from: $0) } as Any? ?? NSNull(),
                            "depth": entry.depth, "isLeader": group.isLeader(member.id), "isCaller": member.id == callerMember.id,
                            "parentMemberID": group.parentID(of: member.id)?.uuidString as Any? ?? NSNull(),
                            "connected": live != nil, "phase": phase?.rawValue as Any? ?? NSNull(),
                            "connectionState": live != nil ? "verified" : SessionGroupMatching.connection(member, in: observed) != nil ? "identity_unverified" : "disconnected",
                            "canReconnect": canReconnectGroupMember(member, group: group, caller: caller, callerMember: callerMember, observed: observed),
                            "canAskQuestion": member.id != callerMember.id && live?.conversationID.flatMap(UUID.init(uuidString:)) != nil && UUID(uuidString: callerMember.conversationID) != nil,
                            "canAssign": group.canDirect(callerMember.id, worker: member.id),
                            "task": groupTaskJSON(state.current(groupID: group.id, workerMemberID: member.id))]
                }
                // Reading is not an ACK. A lost tool response must leave the report pending.
                let reports = state.undelivered.filter { $0.groupID == group.id && $0.parentMemberID == callerMember.id }
                let waits = try groupMailbox().visibleWaits(group.id)
                var result: JSONObject = ["id": group.id.uuidString, "name": group.name, "members": members,
                        "leaderMemberIDs": group.leaderMemberIDs.map(\.uuidString),
                        "leaderMemberID": group.leaderMemberID?.uuidString as Any? ?? NSNull(),
                        "callerMemberID": callerMember.id.uuidString,
                        "waits": waits.map(\.json),
                        "mailbox": groupMailboxSummary(groupID: group.id, memberID: callerMember.id),
                        "reports": reports.map { report -> JSONObject in
                            ["taskID": report.id.uuidString, "workerMemberID": report.workerMemberID.uuidString, "task": report.task,
                             "summary": report.summary as Any? ?? NSNull()]
                        }]
                if includeGraph { result["waitGraph"] = SessionGroupMailbox.diagram(waits) }
                return result
            }
            return ["groups": output, "agent": caller.session.agent.rawValue, "attribution": attribution,
                    "message": "자유 형식 질문·답변은 ask_group_question과 reply_group_question을 사용하세요. 그룹장·동료와 Codex↔Claude 모두 지원합니다. 일반 대화는 send_group_message도 사용할 수 있으며 작업·승인 권한을 부여하지 않습니다. canAssign이 true인 직속 구성원에게 assign_group_task로 작업을 지시하세요. Claude 구성원은 claudeStatus가 idle일 때만 지시할 수 있습니다(phase는 화면 판정이라 unknown일 수 있습니다). task.question이 있는 구성원은 answer_group_question으로 선택지 번호를 골라 답하세요. 작업 완료 보고는 로컬 수신함에 저장됩니다. mailbox.inbox 또는 get_group_messages로 읽고 ack_group_messages로 수신 확인하세요."]
        case "assign_group_task":
            guard let groupID = (object["groupID"] as? String).flatMap(UUID.init(uuidString:)),
                  let memberID = (object["memberID"] as? String).flatMap(UUID.init(uuidString:)),
                  let raw = object["task"] as? String else { throw RemoteHTTPError(400, "그룹 ID, 구성원 ID와 작업 내용을 지정해주세요.") }
            guard !groupClearActive(groupID) else { throw RemoteHTTPError(409, "그룹 초기화가 끝난 뒤 새 작업을 지시해주세요.") }
            let task = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !task.isEmpty, task.count <= SessionGroupOrchestration.maximumTaskLength, !task.contains("\0") else {
                throw RemoteHTTPError(400, "작업 내용은 1~\(SessionGroupOrchestration.maximumTaskLength)자로 지정해주세요.")
            }
            if let prefix = SessionGroupOrchestration.commandPrefix(task) {
                throw RemoteHTTPError(400, "작업 내용은 작업자 터미널에 그대로 입력되므로 '\(prefix)'로 시작할 수 없습니다. 문장으로 시작하도록 고쳐 다시 지시하세요.")
            }
            let (group, caller, callerMember, target, worker, current) = try await groupDirectWorker(object, groupID: groupID, memberID: memberID)
            guard groupWorkerActions.insert(worker.id).inserted else { throw RemoteHTTPError(409, "다른 요청이 이 구성원에게 전달 중입니다.") }
            defer { groupWorkerActions.remove(worker.id) }
            // Claude registers its own status; the screen reading reports "unknown" when Claude shows a status line.
            if let status = await claudeStatuses([current])[worker.id] {
                guard ClaudeSessionRegistration.acceptsPrompt(status) else {
                    throw RemoteHTTPError(409, "작업자가 대기 상태가 아닙니다. (Claude 상태: \(status)) 완료 보고를 받은 뒤 다시 지시하세요.")
                }
            } else {
                guard ![.working, .approval, .input, .ended].contains(current.phase) else {
                    throw RemoteHTTPError(409, "작업자가 아직 작업 중이거나 응답을 기다리고 있습니다. 완료 보고를 받은 뒤 다시 지시하세요.")
                }
            }
            var assignment = SessionGroupAssignment(groupID: group.id, workerMemberID: target.id, parentMemberID: callerMember.id,
                                                    workerSessionID: worker.id, parentSessionID: caller.id, task: task)
            assignment.workerConversationID = worker.conversationID
            // Recorded before typing, so a fast completion always finds its task.
            var state = try groupOrchestration()
            if let current = state.current(groupID: group.id, workerMemberID: target.id),
               current.status == .working, current.parentMemberID != callerMember.id {
                throw RemoteHTTPError(409, "다른 상위 세션이 지시한 작업이 진행 중입니다.")
            }
            state.begin(assignment); try saveGroupOrchestration(state)
            // A worker with automatic approval off stops at its first permission
            // prompt, so a group task turns it on before the task is typed.
            let approval = enableGroupWorkerApproval(worker.id)
            do {
                let prompt = SessionGroupOrchestration.taskMessage(assignment)
                try await sendGroupLine(current, text: prompt) {
                    try self.verifyGroupDirection(groupID, caller: callerMember, target: target)
                    if let conversation = assignment.workerConversationID {
                        try self.groupMailbox().recordSubmission(assignment.id, conversation: conversation, prompt: prompt)
                    }
                }
                if var latest = try? groupOrchestration() { latest.markDelivered(assignment.id); try? saveGroupOrchestration(latest) }
            } catch {
                log(AuditEvent(sessionID: worker.id, summary: "세션 그룹 작업 \(assignment.shortID)",
                               outcome: "그룹 작업 전달 실패: " + error.localizedDescription,
                               source: "세션 그룹", tool: "assign_group_task"))
                if var latest = try? groupOrchestration() { latest.cancel(assignment.id); try? saveGroupOrchestration(latest) }
                // Only a task that never reached the terminal restores the previous choice.
                if approval.changed, (error as? RemoteHTTPError)?.diagnostics?["delivery"] == "not_started" {
                    try? setAutomatic(worker.id, enabled: false)
                }
                throw error
            }
            if approval.changed {
                log(AuditEvent(sessionID: worker.id, summary: "세션 그룹 작업 \(assignment.shortID)", outcome: "그룹 작업 자동 승인 켬",
                               source: "세션 그룹", tool: "assign_group_task", request: task))
            }
            log(AuditEvent(sessionID: worker.id, summary: "세션 그룹 작업 \(assignment.shortID)", outcome: "그룹 작업 전달",
                           source: "세션 그룹", tool: "assign_group_task", request: task))
            scheduleGroupDelivery()
            return ["taskID": assignment.id.uuidString, "workerMemberID": target.id.uuidString, "automaticApproval": approval.rawValue,
                    "message": "작업 내용을 작업자 터미널에 사용자가 직접 입력한 것처럼 그대로 입력했습니다. " + approval.message + "작업 완료 보고는 로컬 수신함에 저장됩니다. mailbox.inbox 또는 get_group_messages로 읽고 ack_group_messages로 수신 확인하세요."]
        case "answer_group_question":
            guard let groupID = (object["groupID"] as? String).flatMap(UUID.init(uuidString:)),
                  let memberID = (object["memberID"] as? String).flatMap(UUID.init(uuidString:)),
                  let choice = (object["choice"] as? NSNumber).flatMap({ CFGetTypeID($0) == CFBooleanGetTypeID() ? nil : $0.intValue }) else {
                throw RemoteHTTPError(400, "그룹 ID, 구성원 ID와 선택지 번호(choice)를 지정해주세요.")
            }
            let (_, _, callerMember, target, worker, current) = try await groupDirectWorker(object, groupID: groupID, memberID: memberID)
            guard groupWorkerActions.insert(worker.id).inserted else { throw RemoteHTTPError(409, "다른 요청이 이 구성원에게 전달 중입니다.") }
            defer { groupWorkerActions.remove(worker.id) }
            guard let item = try groupOrchestration().current(groupID: groupID, workerMemberID: memberID), item.status == .working,
                  let question = item.question else {
                throw RemoteHTTPError(409, "이 구성원은 답을 기다리는 질문이 없습니다. get_group_status로 현재 상태를 확인해주세요.")
            }
            guard question.options.indices.contains(choice - 1) else {
                throw RemoteHTTPError(400, "선택지 번호는 1~\(question.options.count) 중에서 지정해주세요.")
            }
            // The worker must still be asking. A permission answer is the user's delegated approval.
            guard current.phase == (question.isPermission ? .approval : .input) else {
                var state = try groupOrchestration(); state.clearQuestion(item.id); try saveGroupOrchestration(state)
                throw RemoteHTTPError(409, "작업자가 더 이상 답을 기다리지 않습니다. get_group_status로 현재 상태를 확인해주세요.")
            }
            if question.isPermission, snapshot.paused {
                throw RemoteHTTPError(409, "자동 승인이 전체 일시정지 중이라 위임 승인을 하지 않습니다. 사용자가 재개한 뒤 다시 답하세요.")
            }
            let frame = try await remoteTerminal(sessionID: worker.id, realtime: true)
            let fresh = question.isPermission ? delegablePermission(sessions[worker.id] ?? current) : frame.question
            guard let live = fresh, live.id == question.id, live.options == question.options else {
                var state = try groupOrchestration(); state.clearQuestion(item.id); try saveGroupOrchestration(state)
                throw RemoteHTTPError(409, "작업자의 질문이 바뀌어 답하지 않았습니다. 새 질문은 다시 보고됩니다.")
            }
            let answer = question.options[choice - 1]
            _ = try await replyTerminalQuestion(current, object: ["questionID": question.id, "revision": frame.revision, "choice": choice - 1],
                                                automaticAuthorization: { try self.verifyGroupDirection(groupID, caller: callerMember, target: target) }, authorizationSource: "세션 그룹",
                                                permission: question.isPermission)
            var state = try groupOrchestration(); state.clearQuestion(item.id); try saveGroupOrchestration(state)
            groupQuestionSeen[item.id] = nil
            log(AuditEvent(sessionID: worker.id, summary: "세션 그룹 작업 \(item.shortID)",
                           outcome: question.isPermission ? "그룹장 위임 승인" : "그룹 질문 답변",
                           source: "세션 그룹", tool: "answer_group_question", request: question.text, answer: answer))
            return ["taskID": item.id.uuidString, "answer": answer, "permission": question.isPermission,
                    "message": (question.isPermission ? "사용자가 위임한 권한 승인에서" : "작업자의 질문에서") +
                        " ‘\(answer)’를 선택했습니다. 작업 완료 보고는 로컬 수신함에 저장됩니다. mailbox.inbox 또는 get_group_messages로 읽고 ack_group_messages로 수신 확인하세요."]
        case "ask_user":
            guard webStatus.ready else { throw RemoteHTTPError(409, "Mac에서 AutoApprove 웹 접속을 켠 뒤 질문을 게시해주세요.") }
            var params = object
            if let id = params["sessionID"] as? String, sessions[id]?.phase == .ended || sessions[id] == nil { params.removeValue(forKey: "sessionID") }
            let request = try webQuestions.create(params, owner: owner)
            return ["request": try encoded(request), "urls": urls("request=" + request.id)]
        case "get_user_answers":
            guard let id = object["requestID"] as? String else { throw RemoteHTTPError(400, "질문 ID를 지정해주세요.") }
            return ["request": try encoded(webQuestions.get(id, owner: owner))]
        case "get_diagnostics": return await diagnostics()
        case "list_screens": return ["sources": try await encoded(testScreens.availableSources())]
        case "start_screen_share":
            guard webStatus.ready else { throw RemoteHTTPError(409, "Mac에서 AutoApprove 웹 접속을 켠 뒤 공유해주세요.") }
            let share = try await testScreens.start(object, owner: owner)
            return ["share": try encoded(share), "urls": urls("share=" + share.id), "message": "휴대폰의 테스트 화면에서 볼 수 있습니다. 시험을 마치면 공유를 종료해주세요."]
        case "stop_screen_share":
            guard let id = object["shareID"] as? String else { throw RemoteHTTPError(400, "공유 ID를 지정해주세요.") }
            try testScreens.stop(id, owner: owner); return ["stopped": true]
        case let name where name.hasPrefix("desktop_"):
            return try await backgroundDesktop.handle(tool: name, object, owner: owner)
        case "disconnect":
            groupMCPIdentities.removeValue(forKey: owner); backgroundDesktop.release(owner: owner)
            testScreens.stopAll(owner: owner); webQuestions.cancel(owner: owner); return ["ok": true]
        default: throw RemoteHTTPError(400, "지원하지 않는 MCP 도구입니다.")
        }
    }

    public func remoteAction(_ object: JSONObject) async throws -> JSONObject {
        guard let action = object["action"] as? String else { throw RemoteHTTPError(400, "동작을 지정해주세요.") }
        if action == "replyWebQuestion" {
            guard let id = object["questionID"] as? String else { throw RemoteHTTPError(400, "질문을 지정해주세요.") }
            try webQuestions.answer(id, answers: object["answers"]); return ["ok": true]
        }
        if action == "stopScreenShare" {
            guard let id = object["shareID"] as? String else { throw RemoteHTTPError(400, "공유를 지정해주세요.") }
            try testScreens.stop(id); return ["ok": true]
        }
        if action == "startScreenShare" {
            guard webStatus.ready else { throw RemoteHTTPError(409, "Mac에서 웹 접속을 켠 뒤 공유해주세요.") }
            let share = try await testScreens.start(["scope": "display", "durationSeconds": 600], owner: "web")
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            return ["share": try JSONSerialization.jsonObject(with: encoder.encode(share))]
        }
        if action == "pause" {
            guard let paused = object["paused"] as? Bool else { throw RemoteHTTPError(400, "일시정지 값을 지정해주세요.") }
            try setPaused(paused); return ["paused": snapshot.paused]
        }
        if action == "resetAllAutomation" {
            let result = try resetAllAutomation()
            return ["ok": true, "allSessions": true, "sessionCount": result.sessionCount,
                    "cancelledTasks": result.cancelledTasks, "awaitingDelivery": result.awaitingDelivery,
                    "automatic": result.automatic, "paused": result.paused, "message": result.message]
        }
        if action == "questionDelay" {
            guard let seconds = object["seconds"] as? Int else { throw RemoteHTTPError(400, "대기 시간을 지정해주세요.") }
            try setQuestionNotificationDelay(seconds); return ["seconds": snapshot.questionNotificationDelay]
        }
        if action == "codexProgressRecovery" {
            guard let enabled=object["enabled"] as? Bool else {throw RemoteHTTPError(400,"진척 확인 설정을 지정해주세요.")}
            try setCodexProgressRecoveryEnabled(enabled);return ["ok":true,"enabled":enabled]
        }
        if action == "mouseActivity" {
            guard let enabled = object["enabled"] as? Bool else { throw RemoteHTTPError(400, "마우스 신호 설정을 지정해주세요.") }
            try setMouseActivity(enabled)
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            return ["mouseActivity": try JSONSerialization.jsonObject(with: encoder.encode(mouseActivity.status))]
        }
        guard let id = object["sessionID"] as? String, let session = sessions[id],
              session.phase != .ended || ["cancelCapacity","read"].contains(action) else { throw RemoteHTTPError(404, "세션이 종료되었거나 찾을 수 없습니다.") }
        if codexAccountInputHeld(id), ["sendMessage", "replyTerminalQuestion", "resumeGoal", "approve", "approveOnce", "resume", "recover", "checkProgress"].contains(action) {
            throw RemoteHTTPError(409, Self.codexAccountHoldMessage, diagnostics: ["delivery": "not_started"])
        }
        if ["osPermissionPolicy","assignOSPermission","removeOSPermissionTarget","acknowledgeOSPermission","respondOSPermission"].contains(action) {
            guard object["policyRevision"] as? String == (session.osPermissionPolicy?.revision ?? "initial"),
                  try remoteProcessVerifier(session) else {
                throw RemoteHTTPError(409,"OS 권한 정책이나 원래 실행이 바뀌었습니다. 최신 상태를 확인한 뒤 다시 선택해주세요.",diagnostics:["delivery":"not_started"])
            }
        }
        switch action {
        case "resumeGoal","cancelGoal": return try await changeCodexGoal(session,object:object,action:action=="resumeGoal" ? .resume:.cancel)
        case "resetAutomation":
            let result = try resetAutomation(id)
            return ["ok": true, "sessionCount": result.sessionCount, "cancelledTasks": result.cancelledTasks,
                    "awaitingDelivery": result.awaitingDelivery, "automatic": result.automatic,
                    "paused": result.paused, "message": result.message]
        case "clearQueuedInputs":
            guard session.agent == .codex, let thread = object["threadID"] as? String,
                  let supplied = object["queueIDs"] as? [String], !supplied.isEmpty, supplied.count <= 100,
                  Set(supplied).count == supplied.count, supplied.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 }),
                  clearingCodexQueues.insert(id).inserted else { throw RemoteHTTPError(409, "삭제할 대기 입력 목록을 다시 확인해주세요.") }
            defer { clearingCodexQueues.remove(id) }
            let target = try await questionTransport.prepareQueue(session, thread)
            guard target.queueAvailable else { throw RemoteHTTPError(409, CodexQueueTransport.unavailableReason) }
            guard thread == target.threadID else { throw RemoteHTTPError(409, "Codex 대화가 바뀌었습니다. 현재 대기 입력을 다시 확인해주세요.") }
            try validateCodexQueueSession(session, threadID: target.threadID)
            try await codexQueue.validate(target, session.cwd)
            let current = try await codexQueue.list(target), pending = Set(current.map(\.id))
            try validateCodexQueueSession(session, threadID: target.threadID)
            let ids = supplied.filter { pending.contains($0) }
            var event = AuditEvent(sessionID: id, summary: "Codex 대기 입력 \(ids.count)개 삭제", outcome: "대기 입력 삭제 확인 중", source: "웹 대기 입력", context: AuditContext(session: session))
            guard log(event) else { throw RemoteHTTPError(409, "삭제 내역을 저장하지 못했습니다.") }
            var removed = 0
            do {
                try validateCodexQueueSession(session, threadID: target.threadID)
                try await codexQueue.validate(target, session.cwd)
                let result = try await codexQueue.delete(target, ids)
                removed = result.removed.count
                let removedIDs = Set(result.removed)
                for question in sessions[id]?.questions ?? [] where question.reply?.queueID.map({ removedIDs.contains($0) }) == true {
                    questionAutomationOverrides[question.id] = .cancelled; cancelAutomaticQuestionReply(question.id)
                    try store.set("questionAutomation:" + question.id, QuestionAutomation.Phase.cancelled.rawValue)
                    try setReply(QuestionReply(phase: .cancelled, answer: question.reply?.answer ?? "", message: "대기 입력을 삭제해 답변 전달을 취소했습니다. 필요하면 다시 답변해주세요."), sessionID: id, question: question, persist: true)
                }
                if let error = result.error { throw AppError.message(error) }
                event.outcome = "대기 입력 \(removed)개 삭제"; _ = log(event)
                return ["ok": true, "removed": removed, "skipped": supplied.count - removed]
            } catch {
                event.outcome = "대기 입력 \(removed)개 삭제 · 나머지 확인 필요"; _ = log(event)
                throw RemoteHTTPError(503, "\(removed)개를 삭제한 뒤 중단되었습니다. 대기 입력 목록을 새로고침해주세요. \(error.localizedDescription)")
            }
        case "automatic":
            guard let enabled = object["enabled"] as? Bool else { throw RemoteHTTPError(400, "자동 승인 값을 지정해주세요.") }
            try setAutomatic(id, enabled: enabled)
        case "checkCodexProgress": try requestCodexProgressCheck(id)
        case "osPermissionPolicy":
            guard let values=object["allowed"] as? [String],values.count<=OSPermissionKind.allCases.count else {throw RemoteHTTPError(400,"허용할 OS 권한 종류를 지정해주세요.")}
            let allowed=values.compactMap(OSPermissionKind.init(rawValue:))
            guard allowed.count==values.count,!allowed.contains(.authentication) else {throw RemoteHTTPError(400,"지원하지 않는 OS 권한 종류입니다. Mac 사용자 인증은 직접 처리해주세요.")}
            try setOSPermissionPolicy(id,allowed:allowed)
        case "assignOSPermission":
            guard let request=object["permissionID"] as? String,let token=object["permissionToken"] as? String,let remember=object["remember"] as? Bool else {throw RemoteHTTPError(400,"원래 OS 요청과 등록 범위를 확인해주세요.")}
            try assignOSPermission(id,requestID:request,token:token,remember:remember)
        case "removeOSPermissionTarget":
            guard let target=object["targetID"] as? String else {throw RemoteHTTPError(400,"등록 앱을 지정해주세요.")}
            try removeOSPermissionTarget(id,targetID:target)
        case "acknowledgeOSPermission":
            guard let request=object["permissionID"] as? String,let token=object["permissionToken"] as? String else {throw RemoteHTTPError(400,"원래 OS 요청을 확인해주세요.")}
            try acknowledgeOSPermission(id,requestID:request,token:token)
        case "respondOSPermission":
            guard let request=object["permissionID"] as? String,let token=object["permissionToken"] as? String,let button=object["buttonID"] as? String else {throw RemoteHTTPError(400,"원래 OS 요청과 선택한 버튼을 확인해주세요.")}
            try respondOSPermission(id,requestID:request,token:token,buttonID:button)
        case "cancelCodexProgress": cancelCodexProgressCheck(id)
        case "reveal": _ = try await reveal(session)
        case "read": try markNotificationsRead(id, interruptionID: object["interruptionID"] as? String)
        case "claudeApprove", "claudeRelease":
            guard let request = object["requestIDForApproval"] as? String else { throw RemoteHTTPError(400, "승인 요청을 지정해주세요.") }
            if action == "claudeApprove" { try answerClaudeApproval(sessionID: id, requestID: request) }
            else { try releaseClaudeApproval(sessionID: id, requestID: request) }
        case "replyQuestion":
            guard let question = object["questionID"] as? String, let answer = object["answer"] as? String else { throw RemoteHTTPError(400, "질문과 답변을 지정해주세요.") }
            try await replyToQuestion(sessionID: id, questionID: question, answer: answer)
            return ["ok": true, "message": sessions[id]?.questions.first(where: { $0.id == question })?.reply?.message ?? "답변을 전달했습니다."]
        case "cleanPastQuestions", "restorePastQuestions":
            return try cleanPastQuestions(sessionID:id,object:object,restore:action == "restorePastQuestions")
        case "replyTerminalQuestion": return try await replyTerminalQuestion(session, object: object)
        case "replyClaudeQuestions":
            guard let request = object["requestIDForApproval"] as? String else { throw RemoteHTTPError(400, "질문 요청을 지정해주세요.") }
            try replyClaudeQuestions(sessionID: id, requestID: request, answers: object["answers"])
        case "beginClaudeQuestion":
            guard let request = object["requestIDForApproval"] as? String,
                  let pending = liveClaudeHooks[request], pending.request.sessionID == id, pending.receipt.response == nil else {
                throw RemoteHTTPError(409, "질문이 이미 처리되었습니다.")
            }
            try store.set("claudeQuestionEditing:" + request, "true")
            var editing = pending; editing.questionEditing = true; liveClaudeHooks[request] = editing
            publish()
        case "sendMessage":
            if object["transport"] as? String == "terminal" { return try await sendOriginalTerminalMessage(session, object: object) }
            guard session.agent == .codex, let message = object["text"] as? String,
                  !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, message.utf8.count <= 32_000, !message.contains("\0") else {
                throw RemoteHTTPError(400, "Codex 메시지를 32,000바이트 이내로 입력해주세요.")
            }
            guard !sendingMessages.contains(id), !remoteInputStopped else { throw RemoteHTTPError(409, "메시지를 전달하고 있습니다. 결과를 확인해주세요.", diagnostics: ["delivery": "not_started"]) }
            sendingMessages.insert(id); defer { sendingMessages.remove(id) }
            let target: CodexReplyTarget
            do { if let value = object["threadID"] {
                guard let thread = value as? String, UUID(uuidString: thread) != nil else { throw RemoteHTTPError(400, "연결한 Codex 대화를 다시 선택해주세요.") }
                target = try await questionTransport.prepareQueue(session, thread)
                guard target.threadID == thread else { throw RemoteHTTPError(409, "Codex 대화가 바뀌었습니다. 다시 연결해주세요.") }
                try validateCodexQueueSession(session, threadID: thread)
                try await codexQueue.validate(target, session.cwd)
                try validateCodexQueueSession(session, threadID: thread)
            } else { target = try await questionTransport.prepareMessage(session) } }
            catch { throw RemoteHTTPError((error as? RemoteHTTPError)?.status ?? 409, error.localizedDescription, diagnostics: ["delivery": "not_started"]) }
            guard !remoteInputStopped, !codexAccountInputHeld(id), let current = sessions[id], current.phase != .ended,
                  current.pid == session.pid, current.started == session.started, current.tty == session.tty,
                  questionThreadBySession[id] == nil || questionThreadBySession[id] == target.threadID else {
                throw RemoteHTTPError(409, "Codex 대화가 바뀌었습니다. 현재 대화를 확인해주세요.", diagnostics: ["delivery": "not_started"])
            }
            var event = AuditEvent(sessionID: id, summary: String(message.prefix(200)), outcome: "메시지 전달 확인 중", source: "웹 메시지", context: AuditContext(session: session), answer: message)
            guard log(event) else { throw RemoteHTTPError(409, "메시지 전달 내역을 저장하지 못했습니다.", diagnostics: ["delivery": "not_started"]) }
            do {
                if object["threadID"] != nil { try validateCodexQueueSession(session, threadID: target.threadID) }
                let receipt = try await questionTransport.send(target, message)
                event.outcome = "메시지 대기열 등록"; _ = log(event)
                return ["ok": true, "queueID": receipt, "message": "Codex 메시지 대기열에 등록했습니다."]
            } catch {
                event.outcome = "메시지 접수 결과 미확인"; _ = log(event); throw error
            }
        case "cancelQuestion":
            guard let question = object["questionID"] as? String else { throw RemoteHTTPError(400, "질문을 지정해주세요.") }
            try cancelQuestionAutomaticReply(sessionID: id, questionID: question)
        case "beginQuestion":
            guard let question = object["questionID"] as? String else { throw RemoteHTTPError(400, "질문을 지정해주세요.") }
            try beginQuestionReply(sessionID: id, questionID: question)
        case "cancelCapacity": cancelCapacityResume(id)
        default: throw RemoteHTTPError(400, "지원하지 않는 동작입니다.")
        }
        if ["osPermissionPolicy","assignOSPermission","removeOSPermissionTarget","acknowledgeOSPermission","respondOSPermission"].contains(action) {
            let encoder=JSONEncoder();encoder.dateEncodingStrategy = .iso8601
            return ["ok":true,"sessionID":id,"osPermissionPolicy":try JSONSerialization.jsonObject(with:encoder.encode(sessions[id]?.osPermissionPolicy ?? OSPermissionPolicy())),
                    "osPermissions":try JSONSerialization.jsonObject(with:encoder.encode(snapshot.osPermissions ?? OSPermissionMonitorStatus()))]
        }
        return ["ok": true]
    }

    public func remoteCodexConversations(sessionID: String) async throws -> RemoteCodexConversations {
        guard let session = sessions[sessionID], session.agent == .codex, session.phase != .ended, session.cwd.hasPrefix("/") else { throw RemoteHTTPError(409, "Codex 실행과 작업 폴더를 확인해주세요.") }
        let target = try await questionTransport.queueHome(session)
        try validateCodexQueueSession(session, threadID: nil)
        if !target.queueAvailable { return RemoteCodexConversations(sessionID: sessionID, items: [], available: false, unavailableReason: CodexQueueTransport.unavailableReason) }
        let items = try await codexQueue.conversations(target, session.cwd)
        try validateCodexQueueSession(session, threadID: nil)
        return RemoteCodexConversations(sessionID: sessionID, items: items)
    }

    public func remoteCodexHistory(sessionID:String,threadID:String?=nil,cursor:String?=nil) async throws -> CodexConversationPage {
        guard let session=sessions[sessionID],session.agent == .codex,session.phase != .ended else {throw RemoteHTTPError(404,"실행 중인 Codex 세션을 선택해주세요.")}
        guard threadID.map({UUID(uuidString:$0) != nil}) ?? true,
              cursor.map({!$0.isEmpty && $0.utf8.count<=8192}) ?? true,cursor==nil || threadID != nil else {throw RemoteHTTPError(400,"대화와 기록 위치를 다시 확인해주세요.")}
        try validateCodexQueueSession(session,threadID:nil)
        let target:CodexReplyTarget
        var matchedName:String?
        if let threadID {target=try await questionTransport.prepareQueue(session,threadID)}
        else {
            do {target=try await questionTransport.prepareMessage(session)}
            catch {
                let home=try await questionTransport.queueHome(session)
                try validateCodexQueueSession(session,threadID:nil)
                let conversations=try await codexQueue.conversations(home,session.cwd)
                try validateCodexQueueSession(session,threadID:nil)
                guard let current=sessions[sessionID],let match=CodexProfileConversationBinding.match(title:current.terminalTitle,cwd:session.cwd,conversations:conversations),let name=match.name else {
                    throw RemoteHTTPError(409,"이 세션의 Codex 대화를 확정하지 못했습니다. 확인할 대화를 선택해주세요.")
                }
                matchedName=name.precomposedStringWithCanonicalMapping
                target=try await questionTransport.prepareQueue(session,match.id)
                guard target.home==home.home,target.threadID==match.id else {throw RemoteHTTPError(409,"Codex 대화 연결이 바뀌었습니다.")}
            }
        }
        guard UUID(uuidString:target.threadID) != nil,threadID==nil || target.threadID==threadID else {throw RemoteHTTPError(409,"원래 Codex 대화를 다시 선택해주세요.")}
        try validateCodexQueueSession(session,threadID:target.threadID)
        var result=try await codexConversation.read(target,session.cwd,cursor)
        try validateCodexQueueSession(session,threadID:target.threadID)
        guard result.threadID==target.threadID,matchedName==nil || CodexProfileConversationBinding.terminalName(sessions[sessionID]?.terminalTitle,cwd:session.cwd)==matchedName else {throw RemoteHTTPError(409,"기록을 읽는 동안 Codex 대화가 바뀌었습니다.")}
        result.sessionID=sessionID
        return result
    }

    private func codexGoalTarget(_ session:AgentSession,threadID:String?) async throws -> CodexReplyTarget {
        let target:CodexReplyTarget
        if let threadID {target=try await questionTransport.prepareQueue(session,threadID)}
        else {target=try await questionTransport.prepareMessage(session)}
        guard UUID(uuidString:target.threadID) != nil,threadID==nil || threadID==target.threadID else {throw RemoteHTTPError(409,"원래 Codex 대화를 다시 선택해주세요.")}
        // Without a control server, only the thread opened by this exact CLI
        // can receive a slash command. A same-folder thread is not sufficient.
        if !target.queueAvailable,threadID != nil {
            let original=try await questionTransport.prepareMessage(session)
            guard original.threadID==target.threadID,original.home==target.home else {throw RemoteHTTPError(409,"선택한 대화가 원래 터미널의 대화와 다릅니다.")}
        }
        try validateCodexQueueSession(session,threadID:target.threadID)
        return target
    }
    private func manualGoalHold(_ id:String)->String {
        if let value=manualGoalHoldCache[id] {return value}
        let value=store.value("manualGoalHold:"+id) ?? "";manualGoalHoldCache[id]=value
        if manualGoalHoldCache.count>512 {manualGoalHoldCache=manualGoalHoldCache.filter {sessions[$0.key] != nil || $0.key==id}}
        return value
    }
    private func hasManualGoalHold(_ id:String)->Bool {codexAccountInputHeld(id) || codexAccountContinuationHeld(id) || !manualGoalHold(id).isEmpty}
    private func codexAccountContinuationHeld(_ id: String) -> Bool {
        guard let session = sessions[id], session.agent == .codex else { return false }
        for state in codexAccountTransitionStates.values {
            var holds=state.continuationHolds ?? state.threads.filter{!$0.active}.reduce(into:[:]){$0[$1.id]=$1.stopToken}
            for (thread,turn) in state.reservations {holds[thread]=turn}
            guard !holds.isEmpty else {continue}
            guard state.witnesses.contains(where: { $0.pid == session.pid && $0.started == session.started && $0.tty == session.tty }) else { continue }
            // Without fresh per-session turn evidence, keep recovery paused.
            // This does not change automatic-approval preferences or block a
            // user's native/web continuation. A new authoritative turn releases
            // only the old turn's continuation hold, including after restore.
            guard let current = codexTurns[id], current.observedAt >= state.since else { return true }
            if let stopped = holds[current.state.threadID] {
                if current.state.turnID == nil || current.state.turnID == stopped { return true }
            }
        }
        return false
    }
    private func setManualGoalHold(_ id:String,_ value:String) throws {
        try store.set("manualGoalHold:"+id,value);manualGoalHoldCache[id]=value
    }
    public func remoteCodexGoal(sessionID:String,threadID:String?=nil) async throws -> RemoteCodexGoal {
        guard let session=sessions[sessionID],session.agent == .codex,session.phase != .ended else {throw RemoteHTTPError(404,"실행 중인 Codex 세션을 선택해주세요.")}
        let target=try await codexGoalTarget(session,threadID:threadID)
        let goal=try await codexGoals.read(target,session.cwd)
        try validateCodexQueueSession(session,threadID:target.threadID)
        if let goal,let hold=try? JSONDecoder().decode(ManualGoalHold.self,from:Data(manualGoalHold(sessionID).utf8)),
           !hold.belongs(to:goal) || hold.action=="resume" && goal.status == .active {
            try setManualGoalHold(sessionID,"")
        }
        var ready=target.queueAvailable,detail="Goal 취소는 목표를 해제합니다. 대화는 보존되며 실행 중인 작업은 계속될 수 있습니다."
        if !ready,goal != nil {
            let frame=try await remoteTerminal(sessionID:sessionID,realtime:true)
            ready=frame.inputReason==nil && frame.keys.contains("submit") && CodexGoalScreen.ready(frame.screen)
            detail=ready ? "원래 터미널에 Goal 명령을 전달합니다. 목표를 취소해도 대화는 보존됩니다.":"원래 터미널이 빈 입력 대기 상태가 되면 Goal을 변경할 수 있습니다. 작성 중인 입력과 실행 중인 작업을 먼저 확인해주세요."
        }
        try validateCodexQueueSession(session,threadID:target.threadID)
        return RemoteCodexGoal(sessionID:sessionID,threadID:target.threadID,goal:goal,revision:goal?.revision,transport:target.queueAvailable ? "control":"terminal",canResume:ready && goal?.canResume==true,canCancel:ready && goal != nil,detail:detail)
    }
    private func changeCodexGoal(_ session:AgentSession,object:JSONObject,action:CodexGoalAction) async throws -> JSONObject {
        let id=session.id
        guard session.agent == .codex,let thread=object["threadID"] as? String,let revision=object["goalRevision"] as? String,
              !changingGoals.contains(id),!automaticInputBusy(id),!remoteInputSessions.contains(id) else {throw RemoteHTTPError(409,"현재 Goal과 진행 중인 입력을 다시 확인해주세요.",diagnostics:["delivery":"not_started"])}
        changingGoals.insert(id);defer {changingGoals.remove(id)}
        let target=try await codexGoalTarget(session,threadID:thread),threadKey=target.home+"\u{0}"+thread
        guard changingGoalThreads.insert(threadKey).inserted else {throw RemoteHTTPError(409,"이 대화의 Goal을 변경 중입니다. 결과를 기다려주세요.",diagnostics:["delivery":"not_started"])}
        defer {changingGoalThreads.remove(threadKey)}
        guard let expected=try await codexGoals.read(target,session.cwd),expected.revision==revision,
              action == .cancel || expected.canResume else {throw RemoteHTTPError(409,"Goal이나 재개 조건이 바뀌었습니다. 최신 목표를 확인해주세요.",diagnostics:["delivery":"not_started"])}
        try validateCodexQueueSession(session,threadID:thread)
        guard !automaticInputBusy(id) else {throw RemoteHTTPError(409,"이미 진행 중인 승인 입력의 결과를 기다려주세요.",diagnostics:["delivery":"not_started"])}
        // Persist the hold before any write. A lost acknowledgement or restart
        // must not let a stale blocked footer revive this user's cancelled Goal.
        try setManualGoalHold(id,String(decoding:JSONEncoder().encode(ManualGoalHold(goal:expected,action:action.rawValue)),as:UTF8.self))
        cancelCapacityResume(id);cancelCodexProgressCheck(id)
        var event=AuditEvent(sessionID:id,summary:action == .resume ? "Goal 재개":"Goal 취소",outcome:"Goal 명령 전달 확인 중",source:"웹 Goal 관리",context:AuditContext(session:session),answer:action.command)
        guard log(event) else {throw RemoteHTTPError(503,"Goal 변경 기록을 저장하지 못했습니다.",diagnostics:["delivery":"not_started"])}
        var started=false
        do {
            if target.queueAvailable {
                try validateCodexQueueSession(session,threadID:thread)
                started=true
                _ = try await codexGoals.change(target,session.cwd,expected,action)
            } else {
                let frame=try await remoteTerminal(sessionID:id,realtime:true)
                guard frame.inputReason==nil,frame.keys.contains("submit"),CodexGoalScreen.ready(frame.screen) else {throw RemoteHTTPError(409,"원래 Codex의 빈 입력창을 확인해주세요. 초안이나 작업을 변경하지 않았습니다.",diagnostics:["delivery":"not_started"])}
                let freshTarget=try await questionTransport.prepareMessage(session)
                guard freshTarget.threadID==thread,freshTarget.home==target.home,
                      try await codexGoals.read(freshTarget,session.cwd)?.revision==revision else {throw RemoteHTTPError(409,"원래 대화나 Goal이 바뀌었습니다.",diagnostics:["delivery":"not_started"])}
                // The input path rechecks process, TTY, exact screen and source
                // immediately before writing, and never retries this command.
                started=true
                _ = try await remoteInput(["sessionID":id,"revision":frame.revision,"kind":"submit","text":action.command],automaticAuthorization:{
                    try self.validateCodexQueueSession(session,threadID:thread)
                    guard self.changingGoals.contains(id) else {throw CancellationError()}
                })
                // Read-only confirmation; never type the command again.
                var confirmed=false
                for _ in 0..<8 {
                    try await Task.sleep(for:.milliseconds(150))
                    let value=try await codexGoals.read(freshTarget,session.cwd)
                    try validateCodexQueueSession(session,threadID:thread)
                    if action == .cancel ? value==nil:value?.status == .active && value?.createdAt==expected.createdAt && value?.objective==expected.objective {confirmed=true;break}
                }
                guard confirmed else {throw AppError.message("Goal 명령의 반영을 아직 확인하지 못했습니다. 자동으로 다시 보내지 않습니다. 상태를 갱신해주세요.")}
            }
            if action == .resume {try setManualGoalHold(id,"")}
            event.outcome=action == .resume ? "Goal 재개 확인":"Goal 취소 확인";_ = log(event)
            return ["ok":true,"message":action == .resume ? "Goal을 재개했습니다.":"Goal을 취소했습니다. 대화는 보존됩니다. 현재 실행 중인 작업은 계속될 수 있습니다."]
        } catch {
            event.outcome=started ? "Goal 결과 확인 필요":"Goal 미전달";_ = log(event)
            var diagnostics=(error as? RemoteHTTPError)?.diagnostics ?? [:]
            if diagnostics["delivery"]==nil {diagnostics["delivery"]=started ? "unknown":"not_started"}
            throw RemoteHTTPError((error as? RemoteHTTPError)?.status ?? 503,error.localizedDescription,diagnostics:diagnostics)
        }
    }

    public func remoteCodexQueue(sessionID: String, threadID: String? = nil) async throws -> RemoteCodexQueue {
        guard let session = sessions[sessionID], session.agent == .codex, session.phase != .ended else {
            throw RemoteHTTPError(404, "Codex 세션이 종료되었거나 찾을 수 없습니다.")
        }
        let target: CodexReplyTarget
        if let threadID { target = try await questionTransport.prepareQueue(session, threadID) }
        else { target = try await questionTransport.prepareMessage(session) }
        try validateCodexQueueSession(session, threadID: target.threadID)
        if !target.queueAvailable { return RemoteCodexQueue(sessionID: sessionID, threadID: target.threadID, items: [], available: false, unavailableReason: CodexQueueTransport.unavailableReason) }
        if threadID != nil { try await codexQueue.validate(target, session.cwd) }
        let items = try await codexQueue.list(target)
        try validateCodexQueueSession(session, threadID: target.threadID)
        return RemoteCodexQueue(sessionID: sessionID, threadID: target.threadID, items: items)
    }

    private func validateCodexQueueSession(_ session: AgentSession, threadID: String?) throws {
        guard !remoteInputStopped, let current = sessions[session.id], current.phase != .ended,
              current.pid == session.pid, current.started == session.started, current.tty == session.tty, current.cwd == session.cwd,
              threadID == nil || questionThreadBySession[session.id] == nil || questionThreadBySession[session.id] == threadID,
              session.id == "process:\(session.pid):\(session.started)",
              try remoteProcessVerifier(session) else {
            throw RemoteHTTPError(409, "Codex 실행이나 대화가 바뀌었습니다. 현재 목록을 다시 확인해주세요.")
        }
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
        guard let root = sessions[id], root.phase != .ended else { return false }
        if claudeParents.count <= sessions.count {
            // The registry flattens verified child links to the live owner.
            // Scan that small index instead of allocating an ownerID cycle set
            // for every unrelated process session on each screen frame.
            return claudeParents.contains { child, owner in
                guard owner == id, let session = sessions[child], session.phase != .ended else { return false }
                return true
            }
        }
        // Persisted parent links can outlive discovery. Avoid scanning a much
        // larger historical index when the current session inventory is smaller.
        return sessions.keys.contains { $0 != id && ownerID($0) == id }
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

    private func projectCodexActivity(_ value: AgentSession) -> AgentSession {
        var session = value
        if session.phase != .ended, session.codexApprovalBinding != nil {
            if let activity = session.codexActivity, Date().timeIntervalSince(activity.observedAt) < 12 {
                session.ownPhase = activity.parent.phase
                session.phase = activity.phase
                session.activityDetail = activity.summary
                session.backgroundMonitoring = activity.children.contains { $0.phase == .working }
                session.idleSince = nil
            } else {
                session.phase = .unknown
                session.codexActivity = nil
                session.activityDetail = "Codex의 실시간 상태를 확인하고 있습니다."
                session.idleSince = nil
            }
        }
        return session
    }

    private func presentedSessions() -> [AgentSession] {
        // Most installs have no verified Claude parent/child relationships.
        // In that common case the ownership graph cannot alter any row, so skip
        // building active-ID, owner, and child indexes for every publication.
        if claudeParents.isEmpty { return Array(sessions.values) }
        // Persisted links can outlive their child process. When no linked child
        // is active, the graph is irrelevant; preserve only the old projection's
        // behavior of disabling automatic mode on ended child rows.
        if !claudeParents.keys.contains(where: { child in
            guard let session = sessions[child] else { return false }
            return session.phase != .ended
        }) {
            return sessions.values.map { value in
                guard value.phase == .ended, claudeParents[value.id] != nil else { return value }
                var endedChild = value
                endedChild.automatic = false
                return endedChild
            }
        }
        // Resolve ownership once per publication, reusing each traversed chain.
        // Most sessions have no parent and need no temporary Set allocation.
        let activeIDs = Set(sessions.values.lazy.filter { $0.phase != .ended }.map(\.id))
        var owners: [String: String] = [:], unresolved = Set<String>()
        for id in sessions.keys {
            guard activeIDs.contains(id) else { continue }
            if claudeParents[id] == nil { owners[id] = id; continue }
            guard owners[id] == nil, !unresolved.contains(id) else { continue }
            var current = id, path: [String] = [], seen = Set<String>()
            var owner: String?
            while true {
                guard activeIDs.contains(current) else { break }
                if let cached = owners[current] { owner = cached; break }
                guard !unresolved.contains(current), seen.insert(current).inserted else { break }
                path.append(current)
                guard let parent = claudeParents[current] else { owner = current; break }
                current = parent
            }
            if let owner {
                for member in path { owners[member] = owner }
            } else { unresolved.formUnion(path) }
        }
        var raw: [AgentSession] = []
        raw.reserveCapacity(sessions.count)
        var childrenByOwner: [String: [AgentSession]] = [:]
        for value in sessions.values {
            var session = value
            if claudeParents[value.id] != nil {
                session.automatic = !parentSaveFailed && owners[value.id].flatMap { sessions[$0]?.automatic } == true
            }
            if claudeParents[value.id] != nil && owners[value.id] == nil && value.phase != .ended {
                session.detail = "메인 세션이 종료되었거나 연결을 확인할 수 없어 자동 승인을 멈췄습니다. 독립적으로 처리하려면 이 세션의 자동 승인을 다시 켜세요."
            }
            raw.append(session)
            if let owner = owners[value.id], owner != value.id {
                childrenByOwner[owner, default: []].append(session)
            }
        }
        func priority(_ phase: SessionPhase) -> Int {
            switch phase { case .input: return 6; case .approval: return 5; case .working: return 4; case .unknown: return 3; case .idle: return 2; case .ended: return 0 }
        }
        return raw.compactMap { value in
            if let root = owners[value.id], root != value.id { return nil }
            var parent = value
            guard let unsortedChildren = childrenByOwner[value.id], !unsortedChildren.isEmpty else { return parent }
            let children = unsortedChildren.sorted {
                if priority($0.phase) != priority($1.phase) { return priority($0.phase) > priority($1.phase) }
                return $0.id < $1.id
            }
            parent.backgroundSessions = children; parent.ownPhase = value.phase
            parent.detail = "메인과 백그라운드의 질문·알림을 함께 표시합니다. 백그라운드 질문은 연결된 Claude 훅으로 처리합니다."
            if let lead = children.first, value.phase == .unknown || priority(lead.phase) > priority(value.phase) {
                parent.phase = lead.phase; parent.idleSince = lead.idleSince
                parent.backgroundMonitoring = lead.backgroundMonitoring
                parent.activityDetail = lead.activityDetail
            }
            parent.lastActivity = children.reduce(value.lastActivity) { max($0, $1.lastActivity) }
            var notices = value.notices ?? []
            for child in children { notices.append(contentsOf: child.notices ?? []) }
            parent.notices = notices.sorted { $0.date > $1.date }
            if parentSaveFailed {
                parent.detail = "메인·백그라운드 연결을 저장하지 못해 백그라운드 자동 승인을 멈췄습니다. 저장 상태를 확인해주세요."
            }
            return parent
        }
    }

    private func reconcileClaudeActivities(_ registrations: [ClaudeSessionRegistration]) {
        // Interactive sessions keep the screen as their source of truth; the registry only
        // fills in when the screen cannot be read (see `presentPhase`).
        var interactive: [String: String] = [:]
        for entry in registrations where entry.kind != "bg" {
            if let status = entry.status { interactive[entry.processID] = status }
        }
        claudeRegistryStatus = interactive
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

    /// Validate cheap guards first, then compare current scalar fields. Lazy
    /// project reads preserve the phase/rank short circuits of the sort policy.
    private func reusingPresentationOrder(_ rows: [AgentSession], ranks: [String: Int], projects: [String: String],
                                         precedes _: (AgentSession, AgentSession) -> Bool) -> [AgentSession]? {
        guard rows.count > 1 else { return rows }
        let previous = snapshot.sessions
        guard previous.count == rows.count else { return nil }
        var positions: [String: Int] = [:]
        positions.reserveCapacity(rows.count)
        for index in rows.indices {
            guard positions.updateValue(index, forKey: rows[index].id) == nil else { return nil }
        }
        for oldIndex in previous.indices {
            guard let index = positions[previous[oldIndex].id],
                  previous[oldIndex].cwd == rows[index].cwd,
                  (previous[oldIndex].phase == .ended) == (rows[index].phase == .ended) else { return nil }
        }
        var result: [AgentSession] = []
        result.reserveCapacity(rows.count)
        var lastIndex: Int?, lastProject: String?
        var lastID = "", lastEnded = false, lastRank = Int.max
        for oldIndex in previous.indices {
            guard let index = positions.removeValue(forKey: previous[oldIndex].id) else { return nil }
            let id = rows[index].id, ended = rows[index].phase == .ended, rank = ranks[id] ?? Int.max
            var project: String?
            if let leftIndex = lastIndex {
                if lastEnded != ended {
                    guard !lastEnded else { return nil }
                } else if lastRank != rank {
                    guard lastRank < rank else { return nil }
                } else {
                    let leftProject = lastProject ?? projects[lastID] ?? rows[leftIndex].project
                    let rightProject = projects[id] ?? rows[index].project
                    if leftProject != rightProject {
                        guard leftProject.localizedStandardCompare(rightProject) == .orderedAscending else { return nil }
                    } else {
                        guard lastID < id,
                              leftProject.utf8.elementsEqual(rightProject.utf8),
                              leftProject.utf16.elementsEqual(rightProject.utf16) else { return nil }
                    }
                    project = rightProject
                }
            }
            result.append(rows[index])
            lastIndex = index; lastID = id; lastEnded = ended; lastRank = rank; lastProject = project
        }
        guard positions.isEmpty else { return nil }
        return result
    }

    private func publish() {
        if screenPublicationDepth > 0 { screenPublicationPending = true; return }
        projectClaudeApprovals()
        projectCapacityResumes()
        let duplicatesBySession = duplicateQuestionIDsBySession()
        var confirmations = QuestionConfirmationCache()
        reconcileAutomaticQuestionReplies(duplicatesBySession: duplicatesBySession, confirmations: &confirmations)
        updateQuestionAutomationStates(duplicatesBySession: duplicatesBySession, confirmations: &confirmations)
#if DEBUG
        debugQuestionConfirmationDetections += confirmations.detectionCount
#endif
        updateInboxes()
        var ranks: [String: Int] = [:]
        ranks.reserveCapacity(sessionOrder.count)
        for (rank, id) in sessionOrder.enumerated() { ranks[id] = rank }
        let rows = presentedSessions().map(projectCodexActivity).map(projectSessionGroup)
        var projects: [String: String] = [:]
        for row in rows where ranks[row.id] == nil { projects[row.id] = row.project }
        let precedes: (AgentSession, AgentSession) -> Bool = {
            if ($0.phase == .ended) != ($1.phase == .ended) { return $0.phase != .ended }
            let left = ranks[$0.id] ?? Int.max, right = ranks[$1.id] ?? Int.max
            if left != right { return left < right }
            let leftProject = projects[$0.id] ?? $0.project, rightProject = projects[$1.id] ?? $1.project
            if leftProject != rightProject { return leftProject.localizedStandardCompare(rightProject) == .orderedAscending }
            return $0.id < $1.id
        }
        let presented = reusingPresentationOrder(rows, ranks: ranks, projects: projects, precedes: precedes)
            ?? rows.sorted(by: precedes)
        // Heartbeats still reconcile timers and notices, but identical state must
        // not invalidate every SwiftUI window and notification subscription.
        if snapshot.sessions != presented { snapshot.sessions = presented }
    }

    /// A single host result is synchronous: publish all of its sessions together, without
    /// holding a batch across an await or delaying independent hooks and user actions.
    private func withScreenPublicationBatch(_ body: () -> Void) {
        screenPublicationDepth += 1
        defer {
            screenPublicationDepth -= 1
            if screenPublicationDepth == 0, screenPublicationPending {
                screenPublicationPending = false
                publish()
            }
        }
        body()
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

    public func markNotificationsRead(_ id: String, interruptionID: String? = nil) throws {
        if let interruptionID, sessions[id]?.interruption?.id != interruptionID {
            throw RemoteHTTPError(409, "오류가 바뀌었습니다. 현재 오류 내용을 확인해주세요.")
        }
        var updated: [String: SessionInbox] = [:], values: [String: String] = [:]
        var interruptions: [String: SessionInterruption] = [:]
        for member in groupIDs(id) {
            if var inbox = inboxes[member], inbox.markRead() {
                values["inbox:\(member)"] = String(decoding: try JSONEncoder().encode(inbox), as: UTF8.self)
                updated[member] = inbox
            }
            if var error = sessions[member]?.interruption, error.acknowledgedAt == nil {
                error.acknowledgedAt = Date()
                values["interruption:\(member)"] = String(decoding: try JSONEncoder().encode(error), as: UTF8.self)
                interruptions[member] = error
            }
        }
        guard !values.isEmpty else { return }
        try store.setValues(values)
        for (member, inbox) in updated {
            inboxes[member] = inbox
            sessions[member]?.notices = inbox.entries.isEmpty ? nil : inbox.entries
        }
        for (member, error) in interruptions { sessions[member]?.interruption = error }
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
        if let saved=store.value("codexApprovalBinding:"+session.id) { session.codexApprovalBinding=try? JSONDecoder().decode(CodexApprovalBinding.self,from:Data(saved.utf8)) }
        if let text=store.value("osPermissionPolicy:"+session.id),let data=text.data(using:.utf8),
           let saved=try? JSONDecoder().decode(OSPermissionPolicyEnvelope.self,from:data),saved.source==osPermissionSource(session) {
            session.osPermissionPolicy=saved.policy
            osPermissionPolicySources[session.id]=saved.source
        }
        session.customization = nil
        if let saved = store.value("customization:\(session.id)"),
           let decoded = try? JSONDecoder().decode(SessionCustomization.self, from: Data(saved.utf8)),
           let value = try? decoded.normalized(), !value.isEmpty {
            session.customization = value
        }
        session.notices = nil
        if let saved = store.value("interruption:\(session.id)") {
            session.interruption = try? JSONDecoder().decode(SessionInterruption.self, from:Data(saved.utf8))
        }
        restoreNotificationReceipts(&session)
        if let saved = store.value("systemSafety:\(session.id)"),
           let state = try? JSONDecoder().decode(SystemSafetyState.self, from: Data(saved.utf8)) {
            systemSafetyStates[session.id] = state; session.systemSafety = state.notice
        }
    }

    private func restoreNotificationReceipts(_ session: inout AgentSession) {
        if let saved = store.value("inbox:\(session.id)"),
           let inbox = try? JSONDecoder().decode(SessionInbox.self, from: Data(saved.utf8)) {
            inboxes[session.id] = inbox
            session.notices = inbox.entries.isEmpty ? nil : inbox.entries
        }
        guard let error = session.interruption else { return }
        if let saved = store.value("interruption:\(session.id)"),
           let current = try? JSONDecoder().decode(SessionInterruption.self, from: Data(saved.utf8)), current.id == error.id {
            session.interruption?.acknowledgedAt = current.acknowledgedAt
        }
        // Older versions stored only the exact inbox receipt; a later error has
        // a different key and must remain unread. Recovery state stays intact.
        if session.interruption?.acknowledgedAt == nil,
           inboxes[session.id]?.isRead(SessionNotice.key(.question, "interruption:" + error.id)) == true {
            session.interruption?.acknowledgedAt = Date()
        }
    }

    private func updateInboxes() {
        noticeKeyCache?.beginPass()
        defer { if noticeKeyCache?.finishPass() == false { noticeKeyCache = nil } }
        var saveError: String?
        let now = Date()
        for id in Array(sessions.keys) {
            guard var session = sessions[id] else { continue }
            let recentCompletion = session.phase != .ended && session.completion.map { now.timeIntervalSince($0.date) <= 300 } == true
            let hasAttentionInputs = session.systemSafety != nil || session.interruption != nil ||
                session.queuedQuestions?.contains(where: \.needsAnswer) == true ||
                session.claudeApprovals?.isEmpty == false || session.pendingSummary != nil || !session.backgroundChildren.isEmpty
            if (session.agent == .shell || !hasAttentionInputs) && !recentCompletion && inboxes[id] == nil { continue }
            var inbox = inboxes[id] ?? SessionInbox()
            let observed = session.phase == .ended || (session.phase != .unknown &&
                (session.agent != .codex || (session.codexQuestionsObservedAt != nil && session.codexQuestionsError == nil)))
            var update = SessionInbox.Update(moving: &inbox, at: now, reconcilesAbsence: observed)
            if session.agent != .shell && hasAttentionInputs {
                session.automatic = effectiveAutomatic(id)
                AttentionRequest.collectInbox(session, paused: snapshot.paused, into: &update, keyCache: &noticeKeyCache)
            }
            if recentCompletion, let completion = session.completion {
                if noticeKeyCache == nil { noticeKeyCache = SessionNotice.KeyCache() }
                update.append(key: noticeKeyCache!.key(.completion, completion.id), kind: .completion, summary: completion.summary)
            }
            if update.count == 0 && inboxes[id] == nil { continue }
            guard update.finish(into: &inbox) else { continue }
            do {
                try store.set("inbox:\(id)", String(decoding: try JSONEncoder().encode(inbox), as: UTF8.self))
                inboxes[id] = inbox
                sessions[id]?.notices = inbox.entries.isEmpty ? nil : inbox.entries
            } catch { saveError = "알림 배지를 저장하지 못했습니다. \(error.localizedDescription)" }
        }
        if snapshot.health.noticeError != saveError { snapshot.health.noticeError = saveError }
    }

    public func refresh() async {
        await refreshDiscovery()
        async let questions = refreshCodexHistory()
        await refreshScreens()
        _ = await questions
        publish()
    }

    private func refreshDiscovery() async {
        guard !discovering else { return }
        discovering = true
        var publishedDiscovery = false
        let epoch = observationEpoch
        defer {
            discovering = false
            if !initialDiscoveryComplete { initialDiscoveryComplete = true }
        }
        do {
            let reader = discoveryReader
            let discovered = try await Task.detached(priority: .utility) { try reader() }.value
            guard !Task.isCancelled, !remoteInputStopped, observationEpoch == epoch else { return }
            let found = ProcessDiscovery.sessions(discovered)
            let identities = found.map(\.id)
            let dueIDs = Set(ProcessDiscovery.workingDirectoryRefreshIDs(identities,
                lastRead: workingDirectoryReadAt, now: ProcessInfo.processInfo.systemUptime))
            let directoryTargets = found.filter { dueIDs.contains($0.id) }
            let directories: [String: String]
            if directoryTargets.isEmpty { directories = [:] }
            else {
                directories = await Task.detached(priority: .utility) {
                    let paths = ProcessDiscovery.workingDirectories(pids: directoryTargets.map(\.pid))
                    return Dictionary(directoryTargets.compactMap { session in paths[session.pid].map { (session.id, $0) } }, uniquingKeysWith: { a, _ in a })
                }.value
            }
            guard !Task.isCancelled, !remoteInputStopped, observationEpoch == epoch else { return }
            let readAt = ProcessInfo.processInfo.systemUptime
            let liveIDs = Set(identities)
            workingDirectoryReadAt = workingDirectoryReadAt.filter { liveIDs.contains($0.key) }
            workingDirectoriesBySession = workingDirectoriesBySession.filter { liveIDs.contains($0.key) }
            for session in directoryTargets { workingDirectoryReadAt[session.id] = readAt }
            workingDirectoriesBySession.merge(directories) { _, latest in latest }
            if snapshot.health.discoveryError != nil { snapshot.health.discoveryError = nil }
            updateDiscovery(found, records: discovered, directories: workingDirectoriesBySession)
            publishedDiscovery = true
        } catch {
            guard !Task.isCancelled, !remoteInputStopped, observationEpoch == epoch else { return }
            if snapshot.health.discoveryError != error.localizedDescription { snapshot.health.discoveryError = error.localizedDescription }
        }
        refreshGitBranches()
        // updateDiscovery publishes the complete successful snapshot itself.
        // Re-running publish here would repeat question reconciliation, inbox
        // projection, session sorting and remote-row construction every poll.
        if !publishedDiscovery { publish() }
    }

    private func refreshCodexHistory() async -> (targetCount: Int, responsive: Bool)? {
        let epoch = observationEpoch
        let automationEpochs = automationRuntime.epochs
        let automationDefaultEpoch = automationRuntime.defaultEpoch
        let codexTargets = sessions.values.filter { $0.agent == .codex && $0.phase != .ended }
        let updates = await codexQuestions.collect(codexTargets)
        guard !Task.isCancelled, !remoteInputStopped, observationEpoch == epoch else { return nil }
        let bindings=Dictionary(uniqueKeysWithValues:codexTargets.map {($0.id,$0.codexApprovalBinding?.threadID)})
        updateCodexQuestions(updates.filter {
            (automationEpochs[$0.sessionID] ?? automationDefaultEpoch) == automationRuntime.epoch($0.sessionID)
                && (bindings[$0.sessionID] ?? nil) == sessions[$0.sessionID]?.codexApprovalBinding?.threadID
        })
        let responsive = codexTargets.contains { target in
            guard let current = sessions[target.id] else { return false }
            return current.unansweredQuestions.contains(where: { $0.hasLaterUserMessage != true }) ||
                capacityStates[target.id].map { $0.phase == .waiting && $0.deadline.timeIntervalSinceNow <= 2 } == true
        }
        return (codexTargets.count, responsive)
    }

    private func reserveQuestionSettingsCacheEntry(_ id: String) {
        if persistedQuestionSettings[id] == nil, persistedQuestionSettings.count >= Self.persistedQuestionSettingsLimit {
            persistedQuestionSettings.removeAll(keepingCapacity: true)
        }
    }

    private func persistedQuestionIsDismissed(_ id: String) -> Bool {
        reserveQuestionSettingsCacheEntry(id)
        var settings = persistedQuestionSettings[id] ?? PersistedQuestionSettings()
        if !settings.dismissalLoaded {
            settings.dismissed = store.value("dismissedQuestion:\(id)") == "true"
            settings.dismissalLoaded = true
            persistedQuestionSettings[id] = settings
        }
        return settings.dismissed
    }

    private func persistedQuestionAutomation(_ id: String) -> QuestionAutomation.Phase? {
        reserveQuestionSettingsCacheEntry(id)
        var settings = persistedQuestionSettings[id] ?? PersistedQuestionSettings()
        if !settings.automationLoaded {
            if let saved = store.value("questionAutomation:\(id)"),
               let phase = QuestionAutomation.Phase(rawValue: saved), [.editing, .cancelled].contains(phase) {
                settings.automation = phase
            }
            settings.automationLoaded = true
            persistedQuestionSettings[id] = settings
        }
        return settings.automation
    }

    private func pollingTargets(_ host: ScreenHost) -> [AgentSession] {
        sessions.values.filter { $0.agent != .shell && $0.terminal == host.kind && $0.phase != .ended }
    }

    private struct ScreenPollingIdentity: Hashable {
        let sessionID: String
        let tty: String
        let screenHandle: String?
    }
    private func pollingIdentities() -> [ScreenHost: Set<ScreenPollingIdentity>] {
        var result = Dictionary(uniqueKeysWithValues: ScreenHost.allCases.map { ($0, Set<ScreenPollingIdentity>()) })
        for session in sessions.values where session.agent != .shell && session.phase != .ended {
            guard let host = ScreenHost(kind: session.terminal) else { continue }
            result[host, default: []].insert(ScreenPollingIdentity(sessionID: session.id, tty: session.tty, screenHandle: session.screenHandle))
        }
        return result
    }

    /// Monitor cadence of each session, from that session's own state. A host
    /// pass reads only the sessions whose cadence is due, so an approval or
    /// question screen in one tab keeps its 0.5-second cadence while idle tabs
    /// stay at three seconds.
    private func screenReadIntervals(_ host: ScreenHost, targets: [AgentSession]) -> [String: TimeInterval] {
        guard !targets.isEmpty, screenConnections[host]?.enabled == true,
              screenConnections[host]?.permissionBlocked != true else {
            return Dictionary(targets.map { ($0.id, 8) }, uniquingKeysWith: min)
        }
        let now = Date()
        // The slow part of automaticInputBusy is scanning pendingActions for a
        // matching session. Index those few actions once instead of doing that
        // search once per terminal target.
        let pendingActionSessions = Set(pendingActions.values.lazy.map(\.sessionID))
        var result: [String: TimeInterval] = [:]
        result.reserveCapacity(targets.count)
        for target in targets {
            let id = target.id
            let hasPriorityInput = remoteInputSessions.contains(id) || remoteInputUntil[id].map { now < $0 } == true
            let hasAutomaticInput = automaticInputSessions.contains(id) || systemSafetyTasks[id] != nil ||
                capacityStates[id]?.phase == .sending || pendingActionSessions.contains(id)
            // An unsent composer draft is .input without any pending request
            // or question. Nothing can be approved until the user sends it, so
            // it reads every 2 s; phone input keeps the 0.35-second cadence.
            let draftOnly = target.phase == .input && !target.pendingInTerminal && target.pendingRequestID == nil &&
                target.pendingSummary == nil && !target.questions.contains { $0.needsAnswer || $0.reply?.phase == .sending }
            let interval = RemoteTerminalPolling.sessionInterval(
                priorityInput: hasPriorityInput || hasAutomaticInput,
                automatic: !snapshot.paused && effectiveAutomatic(id),
                awaitingAnswer: target.phase == .approval || (target.phase == .input && !draftOnly) ||
                    capacityStates[id].map({ $0.phase == .waiting && $0.deadline.timeIntervalSince(now) <= 2 }) == true,
                composerDraft: draftOnly,
                interrupted: target.interruption?.needsAttention == true,
                active: target.phase == .working || target.phase == .unknown,
                unchangedReads: unchangedSessionReads[id] ?? 0)
            result[id] = min(result[id] ?? interval, interval)
        }
        return result
    }

    private func startObservationPolling() {
        guard pollTask != nil, !remoteInputStopped, !Task.isCancelled else { return }
        if historyPollTask == nil {
            let observation = historyPollSignal.observe()
            historyPollTask = Task { [weak self] in
                await observation.waitForChange(timeout: 0)
                while !Task.isCancelled, let self, !self.remoteInputStopped {
                    let started = ProcessInfo.processInfo.systemUptime
                    let state = await self.refreshCodexHistory()
                    if let state, state.targetCount == 0 {
                        // The empty collection closes retained SQLite handles.
                        // With no Codex session, discovery signals the next
                        // useful read; an eight-second timer only repeats the
                        // same empty query and reopens no useful work.
                        await observation.waitForChange()
                        continue
                    }
                    let interval: TimeInterval
                    if state?.responsive == true && !self.snapshot.paused { interval = 1 }
                    else { interval = 2 }
                    await observation.waitForChange(timeout: max(0.1, interval - (ProcessInfo.processInfo.systemUptime - started)))
                }
            }
        }
        for host in ScreenHost.allCases where screenPollTasks[host] == nil {
            guard let observation = screenPollSignals[host]?.observe() else { continue }
            screenPollTasks[host] = Task { [weak self] in
                await observation.waitForChange(timeout: 0)
                var seenRevision: UInt64?
                while !Task.isCancelled, let self, !self.remoteInputStopped {
                    guard self.screenConnections[host]?.enabled == true,
                          self.screenConnections[host]?.permissionBlocked != true else {
                        await observation.waitForChange()
                        continue
                    }
                    if let retryAfter = self.screenConnections[host]?.retryAfter,
                       retryAfter > Date() {
                        await observation.waitForChange(timeout: min(8,retryAfter.timeIntervalSinceNow))
                        continue
                    }
                    let targets = self.pollingTargets(host)
                    guard !targets.isEmpty else {
                        await observation.waitForChange()
                        continue
                    }
                    // A poll signal (session list, automation, permission or
                    // viewer change) reads every tab once, as before. Timer
                    // passes read only the sessions whose own cadence is due.
                    let revision = self.screenPollSignals[host]?.revision
                    let signalled = revision != seenRevision
                    seenRevision = revision
                    if signalled { for target in targets { self.unchangedSessionReads[target.id] = 0 } }
                    let started = ProcessInfo.processInfo.systemUptime
                    let intervals = self.screenReadIntervals(host, targets: targets)
                    let due = signalled ? targets.map(\.id) : RemoteTerminalPolling.dueTargets(targets.map(\.id),
                        intervals: intervals, lastRead: self.screenReadAt, now: started)
                    if !due.isEmpty {
                        let ids = Set(due)
                        await self.refreshScreenHost(host, reportConnecting:false,
                            targets: targets.filter { ids.contains($0.id) }, hostTargets: targets)
                        // A read slower than a session's cadence waits one
                        // full interval after completion instead of starting
                        // the next expensive native read at once.
                        let finished = ProcessInfo.processInfo.systemUptime
                        for id in due where (self.screenReadAt[id] ?? 0) >= started && finished - started >= (intervals[id] ?? 0) {
                            self.screenReadAt[id] = finished
                        }
                    }
                    let currentTargets = self.pollingTargets(host)
                    let delay = RemoteTerminalPolling.nextReadDelay(currentTargets.map(\.id),
                        intervals: self.screenReadIntervals(host, targets: currentTargets), lastRead: self.screenReadAt,
                        now: ProcessInfo.processInfo.systemUptime)
                    await observation.waitForChange(timeout: delay)
                }
            }
        }
    }

    private func refreshGitBranches() {
        guard gitBranchTask == nil else { return }
        let branchTargets = sessions.values.filter { $0.agent != .shell && $0.phase != .ended && !$0.cwd.isEmpty }
        let directories = Dictionary(branchTargets.map { ($0.id, $0.cwd) }, uniquingKeysWith: { _, latest in latest })
        guard !directories.isEmpty else { gitBranchTargets = [:]; return }
        let now = ProcessInfo.processInfo.systemUptime
        guard directories != gitBranchTargets || now - gitBranchRefreshUptime >= 15 else { return }
        gitBranchTargets = directories
        gitBranchRefreshUptime = now
        gitBranchTask = Task { [weak self] in
            let updates = await GitBranchReader.collect(branchTargets)
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
        var needsPublish = false
        for update in updates {
            guard var session = sessions[update.sessionID], session.agent == .codex, session.phase != .ended else { continue }
            if let token=update.progressToken,update.error==nil {codexProgressHistory[session.id]=(token,date)}
            else {codexProgressHistory.removeValue(forKey:session.id)}
            let wasReadable = readableQuestionSessions.contains(session.id)
            let previousQuestions = session.queuedQuestions, previousError = session.codexQuestionsError
            let previousCompletion = session.completion, previousCompletionError = session.completionError
            let previousObservedAt = session.codexQuestionsObservedAt
            var questionsChanged = false
            session.codexQuestionsError = update.error
            session.completionError = update.completionError ?? (update.turn == nil && !update.completionReadPending ? update.error : nil)
            if let turn = update.turn {
                let previousTurn = codexTurns.updateValue((turn, date), forKey: session.id)?.0
                let completed = codexCompletions.observe(turn, sessionID: session.id, at: date)
                if turn.status != "completed" || session.completion?.id != "codex:\(turn.threadID):\(turn.turnID ?? "")" {
                    session.completion = nil
                }
                if turn.status == "completed", previousTurn != turn, let prompt = turn.userPrompt, let turnID = turn.turnID {
                    receiveGroupTurn(conversation: turn.threadID, turn: "codex:" + turnID, prompt: prompt, response: turn.summary)
                }
                if let completed {
                    session.completion = completed
                    if turn.userPrompt.flatMap(SessionGroupMessage.terminalMessageID) == nil {
                        noteGroupCompletion(session.id, completed, conversation: turn.threadID,
                                            prompt: turn.userPrompt, turn: turn.turnID.map { "codex:" + $0 })
                    }
                }
            } else if update.completionReadPending || update.error != nil || update.completionError != nil {
                codexTurns.removeValue(forKey: session.id)
                session.completion = nil
            }
            if update.error == nil, let questions = update.questions {
                let threadID = update.threadID ?? update.turn?.threadID ?? questions.first?.threadID
                    ?? questionThreadBySession[session.id] ?? session.id
                let threadChanged = questionThreadBySession[session.id] != threadID
                if threadChanged {
                    restoredQuestionIDs.formUnion(questions.map(\.id))
                    questionThreadBySession[session.id] = threadID
                    needsPublish = true
                }
                var previousByID: [String: QueuedQuestion] = [:]
                if let previousQuestions {
                    previousByID.reserveCapacity(previousQuestions.count)
                    for previous in previousQuestions where previousByID[previous.id] == nil {
                        previousByID[previous.id] = previous
                    }
                }
                var reconciled: [QueuedQuestion] = []
                reconciled.reserveCapacity(questions.count)
                for var question in questions {
                    guard !persistedQuestionIsDismissed(question.id) else { continue }
                    if questionAutomationOverrides[question.id] == nil,
                       let phase = persistedQuestionAutomation(question.id) {
                        questionAutomationOverrides[question.id] = phase
                        needsPublish = true
                    }
                    if let previous = previousByID[question.id] {
                        let sameRequest = previous.isSameRequest(as: question)
                        question.reply = sameRequest ? previous.reply : nil
                        if sameRequest { question.automation = previous.automation }
                    } else {
                        question.reply = savedReply(question.id)
                    }
                    reconciled.append(question)
                }
                session.queuedQuestions = reconciled
                questionsChanged = session.queuedQuestions != previousQuestions
                if questionsChanged { invalidateDuplicateQuestionIDs() }
                // Successful reads remain authoritative privately; an unchanged
                // list must not repaint every window just to tick a timestamp.
                if session.codexQuestionsObservedAt == nil || questionsChanged || previousError != nil || threadChanged {
                    session.codexQuestionsObservedAt = date
                }
                readableQuestionSessions.insert(session.id)
            } else {
                readableQuestionSessions.remove(session.id)
            }
            if questionsChanged || session.codexQuestionsError != previousError ||
               session.completion != previousCompletion || session.completionError != previousCompletionError ||
               session.codexQuestionsObservedAt != previousObservedAt ||
               readableQuestionSessions.contains(session.id) != wasReadable {
                needsPublish = true
            }
            sessions[session.id] = session
        }
        if needsPublish { publish() }
    }

    public func dismissQuestion(sessionID: String, questionID: String) throws {
        guard let session = sessions[sessionID], session.phase != .ended,
              session.questions.contains(where: { $0.id == questionID }) else { return }
        try store.set("dismissedQuestion:\(questionID)", "true")
        reserveQuestionSettingsCacheEntry(questionID)
        var settings = persistedQuestionSettings[questionID] ?? PersistedQuestionSettings()
        settings.dismissalLoaded = true; settings.dismissed = true
        persistedQuestionSettings[questionID] = settings
        sessions[sessionID]?.queuedQuestions?.removeAll { $0.id == questionID }
        invalidateDuplicateQuestionIDs()
        publish()
    }

    /// Only explicit metadata cleanup. No daemon, terminal, answer or queue writes.
    private func cleanPastQuestions(sessionID:String,object:JSONObject,restore:Bool) throws -> JSONObject {
        guard let session=sessions[sessionID],session.agent == .codex,session.phase != .ended,
              let supplied=object["questions"] as? [JSONObject],!supplied.isEmpty,supplied.count<=512 else {
            throw RemoteHTTPError(400,"정리할 지난 질문 목록을 다시 확인해주세요.")
        }
        var ids=Set<String>(),values:[String:String]=[:]
        for item in supplied {
            guard let id=item["id"] as? String,!id.isEmpty,id.utf8.count<=1024,ids.insert(id).inserted,
                  let token=item["token"] as? String,token.range(of:#"^[a-f0-9]{64}$"#,options:.regularExpression) != nil,
                  !replyingQuestions.contains(id),automaticQuestionReplies[id]?.sending != true else {
                throw RemoteHTTPError(409,"질문을 전달 중이거나 목록이 바뀌었습니다. 현재 질문을 다시 확인해주세요.")
            }
            let marker=PromptDetector.fingerprint(sessionID+"\u{0}"+token)
            if restore {
                guard store.value("cleanedQuestion:\(id)")==marker else {throw RemoteHTTPError(409,"이 Mac에서 정리한 질문만 되돌릴 수 있습니다.")}
            } else {
                guard let question=session.questions.first(where:{$0.id==id}),question.isPastForCleanup,
                      question.cleanupIdentity(sessionID:sessionID)==token else {
                    throw RemoteHTTPError(409,"새 질문이거나 내용·전송 상태가 바뀌었습니다. 목록을 갱신한 뒤 다시 정리해주세요.")
                }
                values["cleanedQuestion:\(id)"]=marker
            }
            values["dismissedQuestion:\(id)"]=restore ? "false":"true"
            values["questionAutomation:\(id)"]=QuestionAutomation.Phase.editing.rawValue
        }
        // Persist the entire observed batch before publishing any removal.
        try store.setValues(values)
        for id in ids {
            cancelAutomaticQuestionReply(id)
            persistedQuestionSettings.removeValue(forKey:id)
            questionAutomationOverrides[id] = .editing
            restoredQuestionIDs.insert(id)
        }
        if !restore {sessions[sessionID]?.queuedQuestions?.removeAll {ids.contains($0.id)}}
        invalidateDuplicateQuestionIDs();publish()
        return ["ok":true,"count":ids.count,"message":restore ? "지난 질문을 다시 표시합니다. 다음 질문 조회에 반영됩니다.":"지난 질문을 정리했습니다. 원본 대화와 대기 입력은 유지됩니다."]
    }

    private func replyTerminalQuestion(_ session: AgentSession, object: JSONObject, automaticAuthorization: (@MainActor () throws -> Void)? = nil,
                                       authorizationSource: String = "현재 모델 자동 유지", permission: Bool = false) async throws -> JSONObject {
        func detect(_ raw: String) -> TerminalChoiceQuestion? {
            permission ? TerminalChoiceQuestion.detectPermission(raw, agent: session.agent) : TerminalChoiceQuestion.detect(raw, agent: session.agent)
        }
        guard let questionID = object["questionID"] as? String, let revision = object["revision"] as? String,
              let index = object["choice"] as? Int,
              let observed = remoteFrames[session.id], observed.frame.revision == revision,
              let question = detect(observed.raw),
              question.id == questionID, question.options.indices.contains(index) else {
            throw RemoteHTTPError(409, "질문이나 선택지가 바뀌었습니다. 현재 질문을 확인해주세요.", diagnostics: ["delivery": "not_started"])
        }
        let receiptKey = "terminalChoice:\(session.id):\(questionID)"
        guard savedReply(receiptKey) == nil || savedReply(receiptKey)?.canRetry == true,
              replyingQuestions.insert(receiptKey).inserted else {
            throw RemoteHTTPError(409, "이미 답변했거나 전송 결과를 확인해야 하는 질문입니다.", diagnostics: ["delivery": "unknown"])
        }
        defer { replyingQuestions.remove(receiptKey); publish() }
        var attempted = false
        func save(_ reply: QuestionReply) throws {
            try store.set("questionReply:\(receiptKey)", String(decoding: JSONEncoder().encode(reply), as: UTF8.self))
            remoteTerminalChanges[session.id]?.notify()
        }
        do {
            let frame = try await remoteTerminal(sessionID: session.id, realtime: true)
            let live = permission ? remoteFrames[session.id].flatMap { detect($0.raw) } : frame.question
            guard frame.revision == revision, let current = live, current.id == questionID,
                  frame.keys.contains("choice"), frame.inputReason == nil else {
                throw RemoteHTTPError(409, "질문이나 입력 연결이 바뀌었습니다. 현재 질문을 확인해주세요.", diagnostics: ["delivery": "not_started"])
            }
            try save(QuestionReply(phase: .sending, answer: question.options[index], message: "원본 질문의 선택을 전송하고 있습니다.", transport: .terminal))
            var input: JSONObject = ["sessionID": session.id, "revision": frame.revision, "questionID": questionID,
                                     "kind": "choice", "text": current.command(for: index)]
            if session.terminal == .orca, let stream = frame.streamID { input["relay"] = true; input["streamID"] = stream }
            attempted = true
            if permission { delegatedPermissionInputs.insert(session.id) }
            defer { delegatedPermissionInputs.remove(session.id) }
            if let automaticAuthorization { _ = try await remoteInput(input, automaticAuthorization: automaticAuthorization, authorizationSource: authorizationSource) }
            else { _ = try await remoteInput(input) }
            let message = "같은 원본 터미널에서 ‘\(question.options[index])’를 선택했습니다."
            try save(QuestionReply(phase: .queued, answer: question.options[index], message: message, transport: .terminal))
            return ["ok": true, "message": message]
        } catch {
            let uncertain = attempted && (error as? RemoteHTTPError)?.diagnostics?["delivery"] != "not_started"
            try? save(QuestionReply(phase: uncertain ? .uncertain : .failed, answer: question.options[index], message: error.localizedDescription, transport: .terminal))
            var diagnostics = (error as? RemoteHTTPError)?.diagnostics ?? [:]
            diagnostics["delivery"] = uncertain ? "unknown" : "not_started"
            throw RemoteHTTPError((error as? RemoteHTTPError)?.status ?? 409, error.localizedDescription, diagnostics: diagnostics)
        }
    }

    private func savedReply(_ questionID: String) -> QuestionReply? {
        guard let json = store.value("questionReply:\(questionID)"),
              var reply = try? JSONDecoder().decode(QuestionReply.self, from: Data(json.utf8)) else { return nil }
        // This legacy error was thrown by lstat, before a socket or submission
        // existed. It is a proven non-write, unlike timeouts after dispatch.
        if reply.phase == .uncertain && reply.message == CodexQueueTransport.unavailableMessage {
            reply.phase = .failed
            reply.message = "이전 답변은 전송되지 않았습니다. 같은 원본 터미널로 다시 보낼 수 있습니다."
        }
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
        reserveQuestionSettingsCacheEntry(questionID)
        var settings = persistedQuestionSettings[questionID] ?? PersistedQuestionSettings()
        settings.automationLoaded = true; settings.automation = phase
        persistedQuestionSettings[questionID] = settings
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

    private func duplicateQuestionIDsBySession() -> [String: Set<String>] {
        guard duplicateQuestionIDsDirty else { return cachedDuplicateQuestionIDsBySession }
        var result: [String: Set<String>] = [:]
        for (id, session) in sessions {
            guard let questions = session.queuedQuestions, !questions.isEmpty else { continue }
            result[id] = duplicateQuestionIDs(questions)
        }
        cachedDuplicateQuestionIDsBySession = result
        duplicateQuestionIDsDirty = false
        return result
    }

    private func invalidateDuplicateQuestionIDs() { duplicateQuestionIDsDirty = true }

    private func questionAutomationBlock(_ question: QueuedQuestion, duplicates: Set<String>) -> QuestionAutomation.Phase? {
        if let override = questionAutomationOverrides[question.id] { return override }
        if duplicates.contains(question.id) { return .duplicate }
        if question.hasLaterUserMessage == true { return .needsReview }
        if restoredQuestionIDs.contains(question.id) { return .restored }
        return nil
    }

    private func automaticQuestionAnswer(sessionID: String, question: QueuedQuestion,
                                         confirmations: inout QuestionConfirmationCache) -> String? {
        guard !nativeUserInputHasPriority(sessionID) else {return nil}
        // The reservation already owns the exact parsed answer for this request.
        // Unrelated publications must not repeat its label/permission analysis.
        if let pending = automaticQuestionReplies[question.id], pending.sessionID == sessionID,
           pending.question.isSameRequest(as: question) { return pending.answer }
        return confirmations.confirmation(sessionID: sessionID, question: question)?.answer
    }

    private func updateQuestionAutomationStates(duplicatesBySession: [String: Set<String>],
                                                confirmations: inout QuestionConfirmationCache) {
        // The map includes every nonempty queue, even if its duplicate set is
        // empty. Rows without questions have no automation state to project.
        for id in duplicatesBySession.keys {
            guard let session = sessions[id], let questions = session.queuedQuestions else { continue }
            let duplicates = duplicatesBySession[id] ?? []
            var updated: [QueuedQuestion]?
            for (index, original) in questions.enumerated() {
                var question = original
                question.automation = nil
                if session.phase != .ended && (question.reply == nil || question.reply?.phase == .cancelled) {
                    if let block = questionAutomationBlock(question, duplicates: duplicates) {
                        question.automation = QuestionAutomation(phase: block)
                    } else if session.automatic,
                              let answer = automaticQuestionAnswer(sessionID: id, question: question, confirmations: &confirmations) {
                        if snapshot.paused {
                            question.automation = QuestionAutomation(phase: .paused, answer: answer)
                        } else if let pending = automaticQuestionReplies[question.id] {
                            question.automation = QuestionAutomation(phase: .scheduled, deadline: pending.deadline, answer: answer)
                        } else if !session.canApprove || session.codexQuestionsError != nil || !readableQuestionSessions.contains(id) {
                            question.automation = QuestionAutomation(phase: .unavailable, answer: answer)
                        }
                    }
                }
                if question != original {
                    if updated == nil { updated = questions }
                    updated?[index] = question
                }
            }
            if let updated { sessions[id]?.queuedQuestions = updated }
        }
    }

    private func reconcileAutomaticQuestionReplies(duplicatesBySession: [String: Set<String>],
                                                   confirmations: inout QuestionConfirmationCache) {
        // A candidate needs a readable source with nonempty questions. Keep
        // processing existing reservations so a lost source cancels at once.
        guard !automaticQuestionReplies.isEmpty ||
            (!readableQuestionSessions.isEmpty && !duplicatesBySession.isEmpty) else { return }
        var candidates: [String: (sessionID: String, question: QueuedQuestion, answer: String)] = [:]
        if !questionAutomationStopped, !snapshot.paused {
            for session in sessions.values where session.agent == .codex && session.automatic && session.canApprove
                && session.codexQuestionsError == nil && readableQuestionSessions.contains(session.id) {
                let duplicates = duplicatesBySession[session.id] ?? []
                for var question in session.questions {
                    let pending = automaticQuestionReplies[question.id]
                    // Keep our reservation during preflight, but never automatically retry
                    // a failed, uncertain, queued, or manually submitted response.
                    guard questionAutomationBlock(question, duplicates: duplicates) == nil,
                          question.reply == nil || question.reply?.phase == .cancelled || (question.reply?.phase == .sending && pending?.sending == true),
                          let answer = automaticQuestionAnswer(sessionID: session.id, question: question, confirmations: &confirmations) else { continue }
                    question.reply = nil; question.automation = nil
                    candidates[question.id] = (session.id, question, answer)
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
            let delay = confirmationDelay, deadline = Date().addingTimeInterval(confirmationDelay)
            let task = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
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
                question: candidate.question, answer: candidate.answer, deadline: deadline, task: task)
        }
    }

    /// Manual replies remain available while automatic approval is paused.
    public func replyToQuestion(sessionID: String, questionID: String, answer: String) async throws {
        if automaticQuestionReplies[questionID]?.sessionID == sessionID {
            cancelAutomaticQuestionReply(questionID)
        }
        try await sendQuestionReply(sessionID: sessionID, questionID: questionID, answer: answer)
    }

    /// Only transient reads before dispatch may be retried. The answer remains
    /// single-use; an ambiguous write is never part of this recovery loop.
    private func prepareQuestionReply(_ session: AgentSession, question: QueuedQuestion, automaticToken: UUID?) async throws -> CodexReplyTarget {
        for attempt in 0...2 {
            guard !Task.isCancelled, !remoteInputStopped, !codexAccountInputHeld(session.id),
                  automaticToken == nil || !codexAccountContinuationHeld(session.id), let current = sessions[session.id], current.phase != .ended,
                  current.codexApprovalBinding?.threadID == session.codexApprovalBinding?.threadID,
                  current.questions.contains(where: { $0.isSameRequest(as: question) }) else {
                throw AppError.message("세션이나 질문이 바뀌어 전송 전에 멈췄습니다.")
            }
            if let token = automaticToken {
                guard !snapshot.paused, current.automatic, automaticQuestionReplies[question.id]?.token == token,
                      !nativeUserInputHasPriority(session.id),questionAutomationOverrides[question.id] == nil else { throw CancellationError() }
            }
            do { return try await questionTransport.prepare(session, question) }
            catch {
                let http = error as? RemoteHTTPError
                let temporary = (error as? CodexHistoryReadError)?.isTemporary == true ||
                    (http?.diagnostics?["delivery"] == "not_started" && [408, 429, 500, 502, 503, 504].contains(http?.status ?? 0))
                guard attempt < 2, temporary else { throw error }
                try await Task.sleep(for: .milliseconds(attempt == 0 ? 60 : 180))
            }
        }
        throw AppError.message("Codex 응답 경로를 확인하지 못했습니다.")
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
            let target = try await prepareQuestionReply(session, question: question, automaticToken: automaticToken)
            guard !Task.isCancelled, !remoteInputStopped, !codexAccountInputHeld(sessionID), target.threadID == question.threadID, let current = sessions[sessionID], current.phase != .ended,
                  current.codexApprovalBinding?.threadID == session.codexApprovalBinding?.threadID,
                  current.questions.contains(where: { $0.isSameRequest(as: question) }) else {
                throw AppError.message("세션이나 질문이 바뀌었습니다. 목록을 새로고침해주세요.")
            }
            if let automaticToken {
                guard !Task.isCancelled, !snapshot.paused, !codexAccountContinuationHeld(sessionID), current.automatic, current.canApprove,
                      !nativeUserInputHasPriority(sessionID),
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
            let reply: QuestionReply
            if target.queueAvailable {
                launched = true
                let queueID = try await questionTransport.send(target, message)
                reply = QuestionReply(phase: .queued, answer: answer,
                    message: "답변을 Codex 대기열에 등록했습니다. Codex가 받을 차례가 되면 전달됩니다.", queueID: queueID)
            } else {
                let frame = try await remoteTerminal(sessionID: sessionID, realtime: true)
                launched = true
                _ = try await sendOriginalTerminalMessage(session, object: ["text": message, "revision": frame.revision], preflight: { _ in
                    let verified = try await self.prepareQuestionReply(session, question: question, automaticToken: automaticToken)
                    guard verified.threadID == question.threadID,
                          self.sessions[sessionID]?.questions.contains(where: { $0.isSameRequest(as: question) }) == true else {
                        throw RemoteHTTPError(409, "질문이나 대화가 바뀌어 답변하지 않았습니다.")
                    }
                    if let automaticToken {
                        guard !Task.isCancelled, !self.snapshot.paused, self.sessions[sessionID]?.automatic == true,
                              !self.nativeUserInputHasPriority(sessionID),
                              self.automaticQuestionReplies[questionID]?.token == automaticToken,
                              verified.automaticReplyUnavailableReason == nil else {
                            throw RemoteHTTPError(409, "자동 응답이 취소되었습니다. 필요하면 직접 답변해주세요.")
                        }
                    }
                })
                reply = QuestionReply(phase: .queued, answer: answer,
                    message: "같은 원본 터미널에 답변을 전달했습니다. Codex가 응답할 차례에 처리합니다.", transport: .terminal)
            }
            do { try setReply(reply, sessionID: sessionID, question: question, persist: true) }
            catch {
                snapshot.health.auditError = error.localizedDescription
                try setReply(reply, sessionID: sessionID, question: question, persist: false)
            }
            audit?.outcome = reply.transport == .terminal ? "답변 원본 터미널 전달" : "답변 대기열 등록"
            if let audit { log(audit, session: session) }
        } catch {
            if (error as? RemoteHTTPError)?.diagnostics?["delivery"] == "not_started" { launched = false }
            let cancelled = automaticToken.map { !launched && (Task.isCancelled || nativeUserInputHasPriority(sessionID) || automaticQuestionReplies[questionID]?.token != $0) } ?? false
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
        let privateTTYs=agentAccounts.privateTTYs
        let found=found.filter{!privateTTYs.contains($0.tty)}
        pruneExpiredRemoteFrames()
        let previousPolling = pollingIdentities()
        let previousCodex = Set(sessions.values.lazy.filter { $0.agent == .codex && $0.phase != .ended }.map(\.id))
        self.records = records
        // Ordinary terminals do not belong in the inventory or its status counts.
        let managed = found.filter { value in
            guard value.agent != .shell else { return false }
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
        var live = Set<String>(), liveCodex = Set<String>()
        live.reserveCapacity(managed.count); liveCodex.reserveCapacity(managed.count)
        for session in managed {
            live.insert(session.id)
            if session.agent == .codex { liveCodex.insert(session.id) }
        }
        let liveTmuxHandles = Set(managed.compactMap(\.tmuxHandle))
        if retainedTmuxHandles != liveTmuxHandles {
            tmuxRelay.retain(handles: liveTmuxHandles)
            retainedTmuxHandles = liveTmuxHandles
        }
        ptySessionBindings = ptySessionBindings.filter { live.contains($0.key) || (try? managedPTY.terminal($0.value).isRunning) == false }
        if retainedDiscoverySessionIDs != live {
            codexCompletions.retain(sessionIDs: live)
            codexTurns = codexTurns.filter { live.contains($0.key) }
            claudeHookObservedAt = claudeHookObservedAt.filter { live.contains($0.key) }
            retainedDiscoverySessionIDs = live
        }
        // One fresh ancestry index per discovery snapshot, built only when an
        // automatic session actually has an original process to remember.
        var recoveryProcesses: [Int32:ProcessRecord]?
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
                // Discovery can supply a fresh queue before the history reader.
                // Keep the cached queue index complete for that ingress too.
                if session.queuedQuestions?.isEmpty == false { invalidateDuplicateQuestionIDs() }
                restorePreferences(&session)
                if let owned = managedPTY.owned(tty: session.tty), ptyAutomatic[owned.descriptor.ptyID] == true {
                    session.automatic = true
                    try? store.set("automatic:\(session.id)", "true")
                }
                session.detail = Self.connectionGuide(session)
            }
            if session.agent == .agy, let event = agyEvents[session.id] { applyAgyState(event, to: &session) }
            sessions[session.id] = session
            rememberExitContext(session,records:records,byPID:&recoveryProcesses)
        }
        for key in Array(sessions.keys) where key.hasPrefix("process:") && !live.contains(key) {
            let newlyEnded = sessions[key]?.phase != .ended
            if newlyEnded { prepareExitRecovery(key); discardGroupMCPIdentities(for: key) }
            sessions[key]?.setPhase(.ended, detail: "프로세스가 종료되었습니다."); sessions[key]?.channel = .none; sessions[key]?.automatic = false
            if sessions[key]?.queuedQuestions?.isEmpty == false { invalidateDuplicateQuestionIDs() }
            sessions[key]?.queuedQuestions = []; sessions[key]?.codexQuestionsError = nil
            agyEvents.removeValue(forKey: key)
            claudeWorkIDs.removeValue(forKey: key)
            clearScreen(key); capacityStates.removeValue(forKey: key)
            if newlyEnded, sessions[key]?.interruption != nil { persistInterruption(key); saveExitRecoveries() }
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
        reconcileCodexApprovalTasks()
        let nextPolling = pollingIdentities()
        for host in ScreenHost.allCases where previousPolling[host] != nextPolling[host] {
            unchangedScreenReads[host] = 0
            screenPollSignals[host]?.notify()
        }
        if previousPolling != nextPolling {
            let monitored = Set(nextPolling.values.flatMap { $0.map(\.sessionID) })
            screenReadAt = screenReadAt.filter { monitored.contains($0.key) }
            unchangedSessionReads = unchangedSessionReads.filter { monitored.contains($0.key) }
            screenReadSucceeded.formIntersection(monitored)
        }
        if previousCodex != liveCodex {
            readableQuestionSessions.formIntersection(liveCodex)
            questionThreadBySession = questionThreadBySession.filter { liveCodex.contains($0.key) }
            historyPollSignal.notify()
        }
        for id in Array(exitRecoveries.keys) where sessions[id]?.phase == .ended {
            advanceExitRecovery(id, records: records, byPID: &recoveryProcesses)
        }
        // Conversation identities can change without a new process, so also recheck every minute.
        let groupCandidates = Set(sessions.values.lazy.filter { $0.phase != .ended }.map(\.id))
        if groupCandidates != groupBadgeSessionIDs || Date().timeIntervalSince(groupBadgeRefreshedAt) >= 60 {
            groupBadgeSessionIDs = groupCandidates
            refreshSessionGroupBadges()
        }
        if !groupClearDiscoveryReady {
            groupClearDiscoveryReady = true
            if (try? loadGroupClears().contains { !$0.done }) == true { scheduleGroupClears() }
        }
        publish()
    }

    /// Discard pending automation synchronously. The original CLI, user drafts,
    /// saved policy and receipts for already dispatched input are not restarted.
    @discardableResult public func resetAutomation(_ id: String) throws -> AutomationResetResult {
        guard !remoteInputStopped, let selected = sessions[id], selected.phase != .ended else {
            throw AppError.message("실행 중인 세션을 선택해주세요.")
        }
        return resetAutomation(members: Set(groupIDs(id)), selected: selected, allSessions: false)
    }

    /// One actor transaction for every session, including orphaned/ended work.
    /// This never restarts the original CLIs or changes their saved policy.
    @discardableResult public func resetAllAutomation() throws -> AutomationResetResult {
        guard !remoteInputStopped else { throw AppError.message("앱이 종료 중입니다. 다시 실행한 뒤 초기화해주세요.") }
        var members = Set(sessions.keys)
        members.formUnion(automationRuntime.sessionIDs)
        members.formUnion(screens.keys); members.formUnion(screenAnalyses.keys)
        members.formUnion(activityTrackers.keys); members.formUnion(screenObservedAt.keys)
        members.formUnion(capacityStates.keys); members.formUnion(exitRecoveries.keys)
        members.formUnion(exitRecoveryTasks.keys); members.formUnion(modelRetentionTasks.keys)
        members.formUnion(systemSafetyStates.keys); members.formUnion(systemSafetyTasks.keys)
        members.formUnion(resetApprovalReceipts.keys); members.formUnion(remoteInputUntil.keys)
        members.formUnion(remoteStreams.keys); members.formUnion(retainedModelMenus.keys)
        members.formUnion(remoteScreenReads.keys); members.formUnion(remoteInitialReads.keys)
        members.formUnion(remoteObservedScreens.keys); members.formUnion(remoteFrames.keys)
        members.formUnion(remoteMonitorFrames.keys)
        members.formUnion(automaticQuestionReplies.values.map(\.sessionID))
        members.formUnion(liveClaudeHooks.values.map { $0.request.sessionID })
        return resetAutomation(members: members, selected: nil, allSessions: true)
    }

    private func resetAutomation(members: Set<String>, selected: AgentSession?, allSessions: Bool) -> AutomationResetResult {
        noticeKeyCache = nil
        var busy = automaticInputSessions
        busy.formUnion(systemSafetyTasks.keys)
        busy.formUnion(capacityStates.compactMap { $0.value.phase == .sending ? $0.key : nil })
        busy.formUnion(pendingActions.values.map(\.sessionID))
        let awaitingDelivery = !members.isDisjoint(with: busy.union(remoteInputSessions)) ||
            automaticQuestionReplies.values.contains { members.contains($0.sessionID) && $0.sending }
        var cancelledTasks = allSessions ? automationRuntime.resetAll() : 0
        let questionIDs = automaticQuestionReplies.compactMap { members.contains($0.value.sessionID) ? $0.key : nil }
        for questionID in questionIDs { cancelledTasks += 1; cancelAutomaticQuestionReply(questionID) }
        let hookIDs = liveClaudeHooks.compactMap { members.contains($0.value.request.sessionID) ? $0.key : nil }
        for requestID in hookIDs { removeLiveClaudeHook(requestID) }
        if allSessions { automationNeedsFreshScreen.removeAll(); persistedQuestionSettings.removeAll() }
        var hosts = Set<ScreenHost>()
        for member in members {
            if !allSessions { cancelledTasks += automationRuntime.reset(member) }
            if let state = screens[member], let dispatchID = state.dispatchID, busy.contains(member) {
                resetApprovalReceipts[member] = ResetApprovalReceipt(dispatchID: dispatchID,
                    generation: state.generation, requestIdentity: state.prompt.requestIdentity)
            } else if !busy.contains(member) { resetApprovalReceipts.removeValue(forKey: member) }
            if modelRetentionTasks[member] != nil { cancelledTasks += 1 }
            cancelModelRetention(member)
            systemSafetyTasks.removeValue(forKey: member)
            // Editing/cancellation and submission receipts are user intent, not
            // disposable automation. Reload their small caches on the next read.
            if !allSessions {
                for question in sessions[member]?.questions ?? [] { persistedQuestionSettings.removeValue(forKey: question.id) }
            }
            readableQuestionSessions.remove(member)
            capacityStates.removeValue(forKey: member)
            exitRecoveryTasks.removeValue(forKey: member)
            exitRecoveries.removeValue(forKey: member)
            exitLaunchReads.removeValue(forKey: member)?.cancel()
            remoteInputUntil.removeValue(forKey: member)
            retainedModelMenus.removeValue(forKey: member)
            // An interrupted safety write cannot become another Escape or paste.
            var safetyReceipt = systemSafetyStates[member].flatMap { $0.notice.phase == .uncertain ? $0 : nil }
            if var state = systemSafetyStates[member],
               [.cancelling, .typing, .draft, .submitting].contains(state.notice.phase) {
                state.notice.phase = .uncertain
                state.notice.message = "자동화를 초기화했습니다. 이미 전달 중이던 보호 입력은 반복하지 않습니다. 원본 화면을 확인해주세요."
                safetyReceipt = state
                do { try saveSystemSafety(member, state) }
                catch { snapshot.health.auditError = "초기화한 보호 입력의 확인 기록을 저장하지 못했습니다. " + error.localizedDescription }
            }
            systemSafetyStates.removeValue(forKey: member)
            sessions[member]?.systemSafety = nil
            // Keep this minimal receipt even if SQLite is unavailable. Losing
            // it must never turn an unknown paste into a second write.
            if let safetyReceipt { systemSafetyStates[member] = safetyReceipt; sessions[member]?.systemSafety = safetyReceipt.notice }
            clearScreen(member)
            remoteStreams.removeValue(forKey: member)
            if let session = sessions[member], session.phase != .ended {
                automationNeedsFreshScreen.insert(member)
                if let host = ScreenHost(kind: session.terminal) { hosts.insert(host) }
            } else { automationNeedsFreshScreen.remove(member) }
        }
        if allSessions {
            // Release the empty tables too, rather than keeping the capacity
            // allocated by many previous sessions. Delivery receipts stay live.
            screens.removeAll(); screenAnalyses.removeAll(); screenAnalysisCacheBytes = 0
            activityTrackers.removeAll(); screenObservedAt.removeAll()
            remoteStreams.removeAll(); remoteMonitorFrames.removeAll()
            remoteObservedScreens.removeAll(); remoteFrames.removeAll()
            remoteScreenReads.removeAll(); remoteInitialReads.removeAll()
            capacityStates.removeAll(); exitRecoveries.removeAll(); exitRecoveryTasks.removeAll()
            exitLaunchReads.values.forEach { $0.cancel() }; exitLaunchReads.removeAll()
            modelRetentionTasks.removeAll(); systemSafetyTasks.removeAll()
            automaticQuestionReplies.removeAll(); retainedModelMenus.removeAll()
            remoteInputUntil.removeAll(); readableQuestionSessions.removeAll()
            unchangedScreenReads.removeAll(); hosts.formUnion(screenConnections.keys)
        }
        for host in hosts { unchangedScreenReads[host] = 0; screenPollSignals[host]?.notify() }
        let count = allSessions ? sessions.values.filter { $0.phase != .ended }.count : members.count
        let automatic = selected.map { effectiveAutomatic($0.id) } ?? sessions.values.contains { $0.phase != .ended && effectiveAutomatic($0.id) }
        let result = AutomationResetResult(sessionCount: count, cancelledTasks: cancelledTasks,
            awaitingDelivery: awaitingDelivery, automatic: automatic, paused: snapshot.paused, allSessions: allSessions)
        if let selected { sessions[selected.id]?.activityDetail = result.message }
        _ = log(AuditEvent(sessionID: selected?.id ?? "all-sessions", summary: allSessions ? "모든 세션 자동화 초기화·재실행" : "자동화 초기화·재실행", outcome: result.message,
            source: "자동화 복구", context: selected.map { AuditContext(session: $0) }))
        historyPollSignal.notify()
        claudeHookSignals.values.forEach { $0.notify() }
        publish()
        return result
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
        if !enabled {
            for member in groupIDs(target) {
                cancelCodexProgressCheck(member);codexProgressTrackers.removeValue(forKey:member)
                if sessions[member]?.codexProgressRecovery?.phase != .review {sessions[member]?.codexProgressRecovery=nil}
                cancelModelRetention(member)
                cancelCapacityResume(member)
                capacityStates.removeValue(forKey: member)
                exitRecoveries[member]?.automaticCancelled = true
            }
            saveExitRecoveries()
        }
        publish()
        if enabled {
            for member in groupIDs(target) {
                scheduleSystemSafety(member); scheduleScreenApproval(member)
                if let current = sessions[member], let host = ScreenHost(kind: current.terminal) {
                    unchangedScreenReads[host] = 0
                    screenPollSignals[host]?.notify()
                }
            }
            historyPollSignal.notify()
            claudeHookSignals.values.forEach { $0.notify() }
        }
        Task { await evaluateKeepAwake() }
    }
    public func setPaused(_ paused: Bool) throws {
        if paused {cohortExecutionTasks.values.forEach{$0.cancel()}}
        snapshot.paused = paused; revision &+= 1
        if paused {
            for id in Array(codexProgressJobs.keys) {cancelCodexProgressCheck(id)}
            codexProgressTrackers.removeAll()
            for id in sessions.keys where sessions[id]?.codexProgressRecovery?.phase != .review {sessions[id]?.codexProgressRecovery=nil}
        }
        if paused { for id in Array(modelRetentionTasks.keys) { cancelModelRetention(id) } }
        for id in screens.keys { screens[id]?.scheduledID = nil }
        for id in Array(capacityStates.keys) { capacityStates[id]?.scheduledID = nil }
        try store.set("paused", paused ? "true" : "false")
        if !paused {
            for id in screens.keys { scheduleScreenApproval(id) }
            for id in systemSafetyStates.keys { scheduleSystemSafety(id) }
            // A deadline that passed while paused still leaves a moment to cancel.
            for (id, state) in capacityStates where state.phase == .waiting {
                capacityStates[id]?.deadline = max(state.deadline, Date().addingTimeInterval(5))
                scheduleCapacityResume(id)
            }
        }
        publish()
        if !paused {
            for host in ScreenHost.allCases { unchangedScreenReads[host] = 0 }
            screenPollSignals.values.forEach { $0.notify() }; historyPollSignal.notify()
        }
        claudeHookSignals.values.forEach { $0.notify() }
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
        unchangedScreenReads[host] = 0
        screenConnections[host]?.permissionBlocked = false; screenConnections[host]?.retryAfter = .distantPast
        updateHealth(host) { $0.requested = true; $0.status = "연결 확인 중…" }
        await refreshScreenHost(host, reportConnecting: true); publish()
        screenPollSignals[host]?.notify()
    }
    public func disconnectScreenHost(_ host: ScreenHost) {
        screenConnections[host]?.enabled = false; revision &+= 1
        screenPollSignals[host]?.notify()
        unchangedScreenReads[host] = 0
        if host == .tmux { tmuxRelay.stop() }
        for id in sessions.keys where sessions[id]?.terminal == host.kind {
            cancelRemoteInitialRead(id)
            remoteScreenReads.removeValue(forKey: id)?.task.cancel(); remoteFrames.removeValue(forKey: id)
            remoteMonitorFrames.removeValue(forKey: id)
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
    public func refreshScreenHost(_ host: ScreenHost, reportConnecting: Bool = false) async {
        _ = await refreshScreenHost(host, reportConnecting:reportConnecting, targets:nil)
    }

    /// `targets` are read now; `hostTargets` are all of the host's monitored
    /// sessions, so the health line still counts tabs read on an earlier pass.
    @discardableResult
    private func refreshScreenHost(_ host: ScreenHost, reportConnecting: Bool, targets suppliedTargets: [AgentSession]?,
                                   hostTargets: [AgentSession]? = nil) async -> Bool? {
        guard !remoteInputStopped, let connection = screenConnections[host], connection.enabled, !connection.polling, !connection.permissionBlocked,
              Date() >= connection.retryAfter, let adapter = screenAdapters[host] else { return nil }
        screenConnections[host]?.polling = true
        let epoch = observationEpoch
        let automationEpochs = automationRuntime.epochs
        let automationDefaultEpoch = automationRuntime.defaultEpoch
        let announceConnection = reportConnecting || !snapshot.health.screen(host).connected
        if announceConnection { updateHealth(host) { $0.connecting = true } }
        defer {
            screenConnections[host]?.polling = false
            if observationEpoch != epoch { screenPollSignals[host]?.notify() }
            else if announceConnection { updateHealth(host) { $0.connecting = false } }
        }
        let targets = suppliedTargets ?? sessions.values.filter { $0.agent != .shell && $0.terminal == host.kind && $0.phase != .ended }
        let title = host.title
        do {
            let reader = adapter.screens
            let readStartedAt = Date()
            let readStartedUptime = ProcessInfo.processInfo.systemUptime
            var sharedScreens: [String: TerminalScreen] = [:]
            var sharedDates: [String: Date] = [:]
            let sharedPermission: Bool
            let hasRecentViewerFrame = targets.contains { target in
                guard let frame = remoteFrames[target.id], !userInputHasPriority(target.id) else { return false }
                return (0..<0.18).contains(readStartedAt.timeIntervalSince(frame.frame.observedAt))
            }
            if host == .terminal, hasRecentViewerFrame, let target = targets.first, let capture = nativeWindowCapture(for: target) {
                sharedPermission = try await capture.checkAutomationPermission()
            } else { sharedPermission = false }
            if host == .terminal, sharedPermission {
                for target in targets where !userInputHasPriority(target.id) {
                    guard let frame = remoteFrames[target.id],
                          frame.generation == remoteGeneration(target, host: host),
                          let read = remoteScreenReads[target.id], !read.task.isCancelled,
                          read.target == ScreenTarget(tty: target.tty, handle: target.screenHandle),
                          read.generation == frame.generation, read.observedAt == frame.frame.observedAt,
                          read.sourceRevision == remoteTerminalChanges[target.id]?.revision,
                          (0..<0.18).contains(Date().timeIntervalSince(frame.frame.observedAt)) else { continue }
                    guard let observed = try? await read.task.value,
                          observed.generation == frame.generation,
                          observed.observedAt == frame.frame.observedAt,
                          ScreenTextEquality.identical(observed.raw, frame.raw),
                          (0..<0.18).contains(Date().timeIntervalSince(observed.observedAt)) else { continue }
                    sharedScreens[target.tty] = TerminalScreen(tty: target.tty, contents: observed.raw,
                        appearance: observed.appearance?.validated(for: observed.raw),
                        cursor: observed.cursor?.validated(for: observed.raw), display: observed.display?.validated())
                    sharedDates[target.id] = observed.observedAt
                }
            }
            let requests = targets.filter { sharedDates[$0.id] == nil }.map { ScreenTarget(tty: $0.tty, handle: $0.screenHandle) }
            let reusedScreens = sharedScreens, reusedDates = sharedDates
            // The worker needs only this host's active sessions. Retaining the
            // entire cross-host cache pins unrelated terminal scrollback for
            // the duration of a potentially slow Apple Event read.
            var cached: [String: (analysis: ScreenAnalysis?, raw: String, observedAt: Date?)] = [:]
            cached.reserveCapacity(targets.count)
            for target in targets {
                // Prefer the detector's last observed frame. The remote monitor
                // may advance while hook-owned input intentionally skips analysis.
                if let previous = remoteObservedScreens[target.id] {
                    cached[target.id] = (screenAnalyses[target.id], previous.raw, previous.observedAt)
                } else if let previous = remoteMonitorFrames[target.id] {
                    cached[target.id] = (screenAnalyses[target.id], previous.raw, nil)
                }
            }
            let analysisTargets = targets.map { (id: $0.id, tty: $0.tty, agent: $0.agent) }
            // A large scrollback in many tabs must not monopolize the UI actor.
            // One bounded worker per host reads and parses; no policy or input is run here.
            let worker = Task.detached(priority: .utility) {
                let result = requests.isEmpty ? TerminalSnapshot() : try reader(requests)
                var screensByTTY = reusedScreens
                screensByTTY.reserveCapacity(result.screens.count)
                for screen in result.screens where screensByTTY[screen.tty] == nil {
                    screensByTTY[screen.tty] = screen
                }
                var analyses: [String: ScreenAnalysis] = [:]
                var sharedAnalyses: [ScreenAnalysisStorageKey: (raw: String, analysis: ScreenAnalysis)] = [:]
                var changedIDs = Set<String>()
                var unchangedObservedAt: [String: Date] = [:]
                for target in analysisTargets {
                    try Task.checkCancellation()
                    guard let screen = screensByTTY[target.tty] else { continue }
                    if let previous = cached[target.id],
                       previous.analysis?.agent == nil || previous.analysis?.agent == target.agent,
                       ScreenTextEquality.identical(previous.raw, screen.contents) {
                        analyses[target.id] = previous.analysis ?? ScreenAnalysis(raw: screen.contents, agent: target.agent)
                        if let observedAt = previous.observedAt { unchangedObservedAt[target.id] = observedAt }
                    } else {
                        changedIDs.insert(target.id)
                        var storageKey: ScreenAnalysisStorageKey?
                        _ = screen.contents.utf8.withContiguousStorageIfAvailable { bytes in
                            if let address = bytes.baseAddress {
                                storageKey = ScreenAnalysisStorageKey(address: UInt(bitPattern: address),
                                    byteCount: bytes.count, agent: target.agent.rawValue)
                            }
                        }
                        if let storageKey, let shared = sharedAnalyses[storageKey],
                           ScreenTextEquality.identical(shared.raw, screen.contents) {
                            analyses[target.id] = shared.analysis
                        } else {
                            let analysis = ScreenAnalysis(raw: screen.contents, agent: target.agent)
                            analyses[target.id] = analysis
                            if let storageKey { sharedAnalyses[storageKey] = (screen.contents, analysis) }
                        }
                    }
                }
                return (result.failures, screensByTTY, analyses, changedIDs, unchangedObservedAt)
            }
            let (failures, screensByTTY, analyses, changedIDs, unchangedObservedAt) = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
            guard !Task.isCancelled, !remoteInputStopped, observationEpoch == epoch, screenConnections[host]?.enabled == true else { return nil }
            let targets = targets.filter { target in
                guard (automationEpochs[target.id] ?? automationDefaultEpoch) == automationRuntime.epoch(target.id),
                      let current = sessions[target.id], current.phase != .ended,
                      current.pid == target.pid, current.started == target.started,
                      current.tty == target.tty, current.terminal == host.kind else { return false }
                if let at = reusedDates[target.id] {
                    guard !userInputHasPriority(target.id),
                          remoteFrames[target.id]?.frame.observedAt == at,
                          remoteFrames[target.id]?.generation == remoteGeneration(current, host: host),
                          remoteScreenReads[target.id]?.sourceRevision == remoteTerminalChanges[target.id]?.revision,
                          (0..<0.18).contains(Date().timeIntervalSince(at)) else { return false }
                }
                if host == .pty {
                    guard let id = ptySessionBindings[target.id], (try? managedPTY.terminal(id).isRunning) == true else { return false }
                }
                return true
            }
            let unchanged = !targets.isEmpty && targets.allSatisfy { screensByTTY[$0.tty] != nil && !changedIDs.contains($0.id) }
            let hasLiveViewer = targets.contains { remoteTerminalChanges[$0.id]?.hasObservers == true }
            unchangedScreenReads[host] = unchanged && !hasLiveViewer
                ? min(unchangedScreenReads[host, default: 0] + 1, 16) : 0
            for target in targets {
                screenReadAt[target.id] = readStartedUptime
                let read = screensByTTY[target.tty] != nil
                if read { screenReadSucceeded.insert(target.id) } else { screenReadSucceeded.remove(target.id) }
                let stable = read && !changedIDs.contains(target.id) && remoteTerminalChanges[target.id]?.hasObservers != true
                unchangedSessionReads[target.id] = stable ? min((unchangedSessionReads[target.id] ?? 0) + 1, 16) : 0
            }
            let readIDs = Set(targets.map(\.id))
            let earlier = (hostTargets ?? []).filter { !readIDs.contains($0.id) }
            let connected = targets.reduce(into: 0) { if screensByTTY[$1.tty] != nil { $0 += 1 } }
                + earlier.reduce(into: 0) { if screenReadSucceeded.contains($1.id) { $0 += 1 } }
            let missing = targets.count + earlier.count - connected
            updateHealth(host) { health in
                health.connected = connected > 0 || targets.isEmpty
                if connected > 0 {
                    health.status = "연결됨 · \(connected)개 세션" + (missing > 0 ? " · \(missing)개 탭 확인 필요" : "")
                } else if targets.isEmpty {
                    health.status = "연결됨 · \(title)에서 실행 중인 CLI 세션 없음"
                } else {
                    health.status = "해당 세션의 \(title) 탭을 읽지 못했습니다. " + (failures.first?.message ?? "닫힌 탭인지 확인한 후 다시 연결해주세요.")
                }
            }
            withScreenPublicationBatch {
                var sessionProjectionChanged = false
                for target in targets {
                    guard let screen = screensByTTY[target.tty] else {
                        if sessions[target.id]?.channel != .hook {
                            let detail = "이 세션의 \(title) 탭을 읽지 못했습니다. " + (failures.first(where: { $0.tty == target.tty })?.message ?? "탭이 열려 있는지 확인해주세요.")
                            let phaseDetail = "현재 \(title) 화면을 읽지 못했습니다."
                            if sessions[target.id].map({ $0.channel != .none }) == true || sessions[target.id]?.phase != .unknown ||
                                sessions[target.id]?.pendingSummary != nil || sessions[target.id]?.pendingInTerminal == true ||
                                sessions[target.id]?.pendingRequestID != nil || sessions[target.id]?.systemCommandRisk != nil ||
                                sessions[target.id]?.detail != detail || sessions[target.id]?.activityDetail != phaseDetail {
                                sessions[target.id]?.channel = .none
                                sessions[target.id]?.setPhase(.unknown, detail: phaseDetail)
                                sessions[target.id]?.pendingSummary = nil
                                sessions[target.id]?.detail = detail
                                sessionProjectionChanged = true
                            }
                            let needsClear = screens[target.id] != nil || activityTrackers[target.id] != nil ||
                                screenObservedAt[target.id] != nil || screenAnalyses[target.id] != nil || remoteMonitorFrames[target.id] != nil ||
                                sessions[target.id]?.pendingInTerminal == true || sessions[target.id]?.pendingRequestID != nil ||
                                sessions[target.id]?.systemCommandRisk != nil
                            if needsClear { clearScreen(target.id, keepRemote: true) }
                        }
                        continue
                    }
                    // Preserve the last known display label when an optional
                    // title Apple Event is unavailable; the fresh screen below
                    // remains authoritative for detection and approval.
                    if let title = screen.title, sessions[target.id]?.terminalTitle != title {
                        sessions[target.id]?.terminalTitle = title
                        sessionProjectionChanged = true
                    }
                    if reusedDates[target.id] != nil { RemoteTerminalPerformance.shared.increment(.sharedMonitorScreens) }
                    if [.terminal, .iterm].contains(host), reusedDates[target.id] == nil {
                        remoteMonitorFrames[target.id] = RemoteObservedScreen(raw: screen.contents,
                            generation: remoteGeneration(target, host: host), observedAt: readStartedAt,
                            appearance: screen.appearance?.validated(for: screen.contents), cursor: screen.cursor?.validated(for: screen.contents), display: screen.display?.validated())
                    }
                    if sessions[target.id]?.channel != .hook || sessions[target.id]?.pendingInTerminal == true {
                        if sessions[target.id]?.channel != .hook, sessions[target.id]?.channel != host.channel {
                            sessions[target.id]?.channel = host.channel
                            sessionProjectionChanged = true
                        }
                        let detail = "화면의 실행 권한 확인을 감지합니다. 일반 질문은 직접 답해주세요."
                        if sessions[target.id]?.detail != detail {
                            sessions[target.id]?.detail = detail
                            sessionProjectionChanged = true
                        }
                        // Another actor task may have observed a newer frame while
                        // this host read was suspended; only trust the skip if the
                        // captured observation timestamp still owns the current one.
                        let contentsUnchanged = unchangedObservedAt[target.id].map { $0 == remoteObservedScreens[target.id]?.observedAt } ?? false
                        receiveScreen(sessionID: target.id, raw: screen.contents, generation: "\(host.rawValue):\(target.id)", source: host.channel, at: reusedDates[target.id] ?? readStartedAt, appearance: screen.appearance, cursor: screen.cursor, display: screen.display, precomputed: analyses[target.id], screenContentsUnchanged: contentsUnchanged)
                    }
                }
                if sessionProjectionChanged { publish() }
            }
            return unchanged
        } catch {
            guard !Task.isCancelled, !remoteInputStopped, observationEpoch == epoch else { return nil }
            // Denied Automation stays blocked until the user reconnects; other failures retry.
            let blocked = error is TerminalAdapterError
            screenConnections[host]?.permissionBlocked = blocked
            screenConnections[host]?.retryAfter = Date().addingTimeInterval(5)
            updateHealth(host) { $0.connected = false; $0.status = error.localizedDescription + (blocked ? "" : " · 자동 재연결 대기") }
            for id in Array(sessions.keys) where sessions[id]?.channel == host.channel && sessions[id]?.phase != .ended {
                sessions[id]?.channel = .none; sessions[id]?.setPhase(.unknown, detail: "\(title) 연결이 끊겨 현재 상태를 확인할 수 없습니다."); clearScreen(id, keepRemote: !blocked)
            }
            publish()
            unchangedScreenReads[host] = 0
            // After a failed host read, the next successful pass reads every tab.
            for target in targets { screenReadSucceeded.remove(target.id); unchangedSessionReads[target.id] = 0 }
            screenPollSignals[host]?.notify()
            return nil
        }
    }

    public func reveal(_ session: AgentSession) async throws -> TerminalWindowBounds? {
        let live = try await Task.detached { try ProcessDiscovery.read(pid: session.pid) }.value
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
    public func upgradeClaudeHooks(executable: String, settingsURL:URL = HookInstaller.settingsURL) {
        // A duplicate/failed launch must not replace the active app's helper.
        guard server != nil else{return}
        do { try HookInstaller.upgradeTimeouts(executable: executable,home:paths.directory.path,url:settingsURL) }
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

    private func rememberAuditEvent(_ event: AuditEvent) {
        if let index = snapshot.events.firstIndex(where: { $0.id == event.id }) { snapshot.events[index] = event }
        else { snapshot.events.insert(event, at: 0) }
        if snapshot.events.count > 200 { snapshot.events.removeLast(snapshot.events.count - 200) }
    }

    @discardableResult private func log(_ event: AuditEvent, session: AgentSession? = nil) -> Bool {
        let event = contextualEvent(event, session: session)
        do { try store.append(event); snapshot.health.auditError = nil }
        catch { snapshot.health.auditError = error.localizedDescription; return false }
        rememberAuditEvent(event)
        return true
    }

    /// Legacy helpers pass unanswered requests back to Claude. New helpers use the durable bridge below.
    public func handleHook(_ payload: JSONObject, deferApproval: Bool = false) -> JSONObject {
        handleHook(payload, deferApproval: deferApproval, prepared: nil)
    }
    private func handleHook(_ payload: JSONObject, deferApproval: Bool, prepared: ClaudeHookRequest?) -> JSONObject {
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
        let summary = prepared?.summary ?? QuestionDetector.hookSummary(tool: tool, input: input, message: payload["message"] as? String)
        let request: String?
        if let prepared { request = prepared.inputJSON }
        else { request = (try? JSONSerialization.data(withJSONObject: input, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])).map { String(decoding: $0, as: UTF8.self) } }
        let needsAnswer = ["AskUserQuestion", "ExitPlanMode", "EnterPlanMode"].contains(tool)
        let risk: SystemCommandRisk?
        // A missing/empty payload cwd can inherit a different session cwd.
        // Reinspect in that effective directory; never cache installer sources.
        if let prepared, (payload["cwd"] as? String ?? "") == session.cwd { risk = prepared.systemCommandRisk }
        else { risk = ["PreToolUse", "PermissionRequest"].contains(event)
            ? SystemCommandRisk.detect(tool: tool, input: input, summary: summary, cwd: session.cwd) : nil
        }
        if event != "Notification" { session.systemCommandRisk = risk }
        if ["UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest"].contains(event) {
            if event == "UserPromptSubmit" || claudeWorkIDs[key] == nil { claudeWorkIDs[key] = UUID().uuidString }
            session.completion = nil
        } else if event == "SessionStart" || event == "SessionEnd" {
            agyEvents.removeValue(forKey: key)
            claudeWorkIDs.removeValue(forKey: key); session.completion = nil
        }
        if event == "UserPromptSubmit" {
            claudeGroupPrompts.removeValue(forKey: key)
            if lineageVerified, let prompt = payload["prompt"] as? String {
                let turn = "claude:" + requestID
                claudeGroupPrompts[key] = (prompt, turn)
                if SessionGroupMessage.terminalMessageID(prompt) != nil {
                    receiveGroupTurn(conversation: providerID, turn: turn, prompt: prompt, response: nil)
                } else if let task = try? groupOrchestration().assignments.last(where: {
                    $0.workerSessionID == key && $0.workerConversationID?.lowercased() == providerID.lowercased() &&
                        $0.status == .working
                }), let box = try? groupMailbox() {
                    _ = try? box.transaction {
                        if try box.confirmedPrompt(task.id, conversation: providerID, prompt: prompt),
                           try box.claimTurn(task.id, turn: turn) {
                            try box.notePromptReceipt(task.id)
                        }
                    }
                }
            }
        } else if ["SessionStart", "SessionEnd", "StopFailure"].contains(event) {
            claudeGroupPrompts.removeValue(forKey: key)
        }
        var response: JSONObject = [:]
        if let risk {
            // Legacy hook decisions use the same safe denial as the durable bridge.
            // Denying a tool with a reason leaves Claude free to choose an alternative.
            let toolID = payload["tool_use_id"] as? String ?? requestID
            session.systemSafety = SystemSafetyNotice(id: "hook:" + providerID + ":" + toolID, risk: risk, request: summary)
            session.setPhase(.approval, detail: risk.detail); session.pendingSummary = summary; session.pendingInTerminal = true
            if !deferApproval, lineageVerified, effectiveAutomatic(key, fallback: session), !snapshot.paused {
                let audit = AuditEvent(sessionID: key, summary: summary, outcome: "시스템 변경 거절 · 안전한 대안 안내", source: "Claude 훅",
                    tool: tool, request: request, answer: risk.guidance)
                if log(audit, session: session) {
                    response = risk.denial(event: event)
                    session.systemSafety?.phase = .guided
                    session.systemSafety?.message = "시스템 변경을 거절하고 같은 Claude 대화에 안전한 대안을 전달했습니다."
                    session.setPhase(.working, detail: session.systemSafety!.message)
                    session.pendingSummary = nil; session.pendingInTerminal = false; session.pendingRequestID = nil
                }
            }
            sessions[key] = session
            snapshot.health.claude = "연결됨 · 세션 이벤트 수신 중"; publish()
            return response
        }
        if tool == "AskUserQuestion", ["PreToolUse", "PermissionRequest"].contains(event),
           let confirmation = AutomaticQuestionDecision.detect(input) {
            // tool_use_id joins PreToolUse and PermissionRequest for one logical question.
            let toolID = (payload["tool_use_id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? requestID
            let first = rememberHook(key + ":question:" + providerID + ":" + toolID)
            if first {
                session.setPhase(.input, detail: "Claude가 자동 확인 질문의 응답을 기다리고 있습니다.")
                session.pendingSummary = summary; session.pendingInTerminal = true
                session.pendingRequestID = "hook:\(providerID):\(toolID)"
                if !deferApproval, lineageVerified, effectiveAutomatic(key, fallback: session), !snapshot.paused,
                   risk == nil {
                    let audit = AuditEvent(sessionID: key, summary: summary, outcome: "질문 응답 전달", source: "Claude 훅",
                        tool: tool, request: request, answer: confirmation.answer)
                    if log(audit, session: session) {
                        let updated = confirmation.updatedInput(input)
                        if event == "PreToolUse" {
                            response = ["hookSpecificOutput": ["hookEventName": event, "permissionDecision": "allow", "updatedInput": updated]]
                        } else {
                            response = ["hookSpecificOutput": ["hookEventName": event, "decision": ["behavior": "allow", "updatedInput": updated]]]
                        }
                        session.setPhase(.working, detail: "확인 질문에 ‘\(confirmation.answer)’ 응답을 전달했습니다.")
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
            if !deferApproval, lineageVerified, effectiveAutomatic(key, fallback: session), !snapshot.paused, first, !needsAnswer,
               risk == nil {
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
        case "SessionEnd":
            sessions[key] = session; prepareExitRecovery(key); session = sessions[key] ?? session
            session.setPhase(.ended, detail: "Claude 세션 종료 이벤트를 받았습니다."); session.automatic = false; session.pendingSummary = nil; session.pendingInTerminal = false
        case "StopFailure":
            let failure = payload["error"] as? String ?? "unknown"
            let detail = payload["last_assistant_message"] as? String ?? payload["error_details"] as? String ?? failure
            session.completion = nil
            session.setPhase(.idle,detail:"Claude가 오류로 요청을 중단했습니다.",monitoring:false)
            session.pendingSummary = nil; session.pendingInTerminal = false; session.pendingRequestID = nil
            if session.interruption?.needsAttention != true {
                session.interruption = SessionInterruption(id:UUID().uuidString,kind:.claudeFailure(failure),detail:detail)
            }
        case "Stop":
            let groupPrompt = claudeGroupPrompts.removeValue(forKey: key)
            guard !session.pendingInTerminal else { break }
            // A normal completion supersedes the preceding failed turn. Keeping its
            // error active would restart the CLI later when the user exits normally.
            if session.interruption?.needsAttention == true {
                session.interruption?.recoveredAt = Date(); session.interruption?.resumeUncertain = false
            }
            capacityStates.removeValue(forKey: key)
            let background = payload["background_tasks"] as? [Any] ?? []
            let scheduled = payload["session_crons"] as? [Any] ?? []
            if !background.isEmpty || !scheduled.isEmpty {
                session.completion = nil
                session.setPhase(.idle, detail: "Claude 응답은 끝났고 다음 지시를 받을 수 있습니다. 백그라운드 작업 또는 예약된 후속 작업을 모니터링 중입니다.", monitoring: true)
                session.pendingSummary = nil
            } else {
                if lineageVerified, let groupPrompt {
                    receiveGroupTurn(conversation: providerID, turn: groupPrompt.turn, prompt: groupPrompt.prompt, response: payload["last_assistant_message"] as? String)
                }
                if let workID = claudeWorkIDs.removeValue(forKey: key) ?? (session.phase == .working ? UUID().uuidString : nil) {
                    let completion = WorkCompletion(id: "claude:\(providerID):\(workID)", summary: payload["last_assistant_message"] as? String)
                    session.completion = completion
                    if groupPrompt.flatMap({ SessionGroupMessage.terminalMessageID($0.prompt) }) == nil {
                        noteGroupCompletion(key, completion, conversation: providerID, prompt: groupPrompt?.prompt, turn: groupPrompt?.turn)
                    }
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
        case "UserPromptSubmit", "PostToolUse":
            if session.interruption?.needsAttention == true { session.interruption?.recoveredAt = Date(); session.interruption?.resumeUncertain = false }
            session.setPhase(.working, detail: "Claude가 요청을 처리하고 있습니다."); session.pendingSummary = nil; session.pendingInTerminal = false
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
        sessions[key] = session
        if groupMailboxTask != nil, session.phase == .idle,
           event == "Stop" || (event == "Notification" && payload["notification_type"] as? String == "idle_prompt") {
            groupMailboxIdleSessions.insert(key)
            groupMailboxSignal.notify()
        }
        if session.interruption != nil { persistInterruption(key) }
        snapshot.health.claude = "연결됨 · 세션 이벤트 수신 중"; publish()
        if event == "UserPromptSubmit", let context = groupDelegationContext(sessionID: key, prompt: payload["prompt"] as? String) {
            response["hookSpecificOutput"] = ["hookEventName": "UserPromptSubmit", "additionalContext": context]
        }
        return response
    }

    /// The user's own hook tells the assigning Claude that the group's decisions were delegated to it.
    /// It is added only to the reports and requests AutoApprove just delivered to that session. A worker's
    /// task gets nothing: it is typed as plain input, exactly as if the user had typed it.
    private func groupDelegationContext(sessionID: String, prompt: String?, at now: Date = Date()) -> String? {
        if let prompt, prompt.hasPrefix("[AutoApprove 그룹 수신함]") || SessionGroupMessage.terminalMessageID(prompt) != nil,
           let receipt = groupMailboxDelegations[sessionID], now.timeIntervalSince(receipt.at) < 600,
           prompt.contains(receipt.id.uuidString) {
            return SessionGroupOrchestration.parentDelegation(group: receipt.group)
        }
        guard let prompt = prompt?.trimmingCharacters(in: .whitespacesAndNewlines),
              prompt.hasPrefix("[AutoApprove 그룹 보고") || prompt.hasPrefix("[AutoApprove 그룹 질문") || prompt.hasPrefix("[AutoApprove 그룹 승인 요청"),
              let state = try? groupOrchestration() else { return nil }
        let delivered = state.assignments.first { item in
            item.parentSessionID == sessionID && [item.reportedAt, item.question?.reportedAt].contains { $0.map { now.timeIntervalSince($0) < 600 } == true }
        }
        guard let delivered else { return nil }
        let groups = (try? SessionGroupStore(directory: paths.directory).load()) ?? []
        return SessionGroupOrchestration.parentDelegation(group: groups.first { $0.id == delivered.groupID }?.name ?? "세션 그룹")
    }

    private func rememberHook(_ fingerprint: String) -> Bool {
        guard handledHookIDs.insert(fingerprint).inserted else { return false }
        hookIDOrder.append(fingerprint)
        if hookIDOrder.count > 4096 { handledHookIDs.remove(hookIDOrder.removeFirst()) }
        return true
    }

    private func bridgeResponse(_ response: JSONObject? = nil) -> JSONObject {
        if let response { return ["autoapproveBridge": ["response": response, "waitSupported": true]] }
        return ["autoapproveBridge": ["waiting": true, "waitSupported": true]]
    }

    /// Hold Claude's hook only for an answer AutoApprove sends within its confirmation delay.
    /// Every other request returns at once, so Claude's own terminal dialog and choices appear.
    private func holdsClaudeHook(_ request: ClaudeHookRequest, questionEditing: Bool) -> Bool {
        guard effectiveAutomatic(request.sessionID), !snapshot.paused else { return false }
        if request.safetyResponse != nil { return true }
        return request.response != nil && !questionEditing
    }

    /// Return a held hook to Claude once AutoApprove can no longer answer it, for example after automatic approval is turned off.
    private func releaseLiveClaudeHook(_ id: String) throws -> JSONObject {
        guard var pending = liveClaudeHooks[id] else { return bridgeResponse([:]) }
        let response = handleHook(pending.request.payload, deferApproval: false, prepared: pending.request)
        pending.receipt.response = String(decoding: try JSONSerialization.data(withJSONObject: response), as: UTF8.self)
        try saveClaudeReceipt(pending.receipt)
        removeLiveClaudeHook(id, terminal: true)
        publish()
        return bridgeResponse(response)
    }

    private func saveClaudeReceipt(_ receipt: ClaudeHookReceipt) throws {
        do {
            try store.saveClaudeHook(receipt)
            if receipt.response != nil { claudeHookSignals[receipt.id]?.notify() }
            snapshot.health.auditError = nil
            if let audit = receipt.audit { rememberAuditEvent(audit) }
        } catch { snapshot.health.auditError = error.localizedDescription; throw error }
    }

    /// Polls carry the original UUID and full input, so a restarted app can resume the exact hook.
    public func handleClaudeHook(_ payload: JSONObject, at now: Date = Date()) throws -> JSONObject {
        guard let envelope = ClaudeHookEnvelope(payload, at: now) else { return bridgeResponse([:]) }
        return try handleClaudeHook(envelope, at: now)
    }

    /// Reuse an immutable, already fingerprinted request across hookWait
    /// heartbeats. Recheck its deadline on every wake; never reserialize and
    /// hash the complete tool input just to establish the same identity again.
    private func handleClaudeHook(_ envelope: ClaudeHookEnvelope, at now: Date) throws -> JSONObject {
        guard envelope.expiresAt > now else { return bridgeResponse([:]) }
        // A live receipt is authoritative within this process: every in-process
        // write updates it before notifying the waiter. Avoid a SQLite read and
        // JSON decode on each helper retry; restart recovery still reads below.
        if var pending = liveClaudeHooks[envelope.id] {
            guard pending.receipt.fingerprint == envelope.fingerprint else { throw AppError.message("같은 요청 ID의 내용이 달라 응답하지 않았습니다.") }
            if let response = pending.receipt.response {
                removeLiveClaudeHook(envelope.id)
                publish()
                return bridgeResponse((try JSONSerialization.jsonObject(with: Data(response.utf8))) as? JSONObject ?? [:])
            }
            if pending.request.systemCommandRisk == nil, pending.request.tool == "Bash",
               let input = envelope.payload["tool_input"] as? JSONObject,
               let command = input["command"] as? String, SystemCommandRisk.mayReferenceInstaller(command) {
                let suppliedCWD = envelope.payload["cwd"] as? String
                let cwd = suppliedCWD.flatMap { $0.isEmpty ? nil : $0 } ?? sessions[pending.request.sessionID]?.cwd ?? ""
                if let risk = SystemCommandRisk.detect(tool: pending.request.tool, input: input,
                                                       summary: pending.request.summary, cwd: cwd) {
                    // The helper is retrying the same pending request, but a
                    // local installer may have changed since it first arrived.
                    // Reclassify it before any automatic or manual answer.
                    pending.request.systemCommandRisk = risk
                    _ = handleHook(envelope.payload, deferApproval: true, prepared: pending.request)
                }
            }
            if !holdsClaudeHook(pending.request, questionEditing: pending.questionEditing) {
                liveClaudeHooks[envelope.id] = pending
                return try releaseLiveClaudeHook(envelope.id)
            }
            pending.lastContact = now
            liveClaudeHooks[envelope.id] = pending
            try answerClaudeHookIfEligible(pending, at: now)
            if let response = liveClaudeHooks[envelope.id]?.receipt.response {
                removeLiveClaudeHook(envelope.id)
                publish()
                return bridgeResponse((try JSONSerialization.jsonObject(with: Data(response.utf8))) as? JSONObject ?? [:])
            }
            publish()
            return bridgeResponse()
        }
        let payload = envelope.payload
        let saved = try store.claudeHook(id: envelope.id)
        if let saved {
            guard saved.fingerprint == envelope.fingerprint else { throw AppError.message("같은 요청 ID의 내용이 달라 응답하지 않았습니다.") }
            if let response = saved.response {
                removeLiveClaudeHook(envelope.id)
                publish()
                return bridgeResponse((try JSONSerialization.jsonObject(with: Data(response.utf8))) as? JSONObject ?? [:])
            }
        }
        let request = ClaudeHookRequest(envelope)
        var receipt = saved ?? ClaudeHookReceipt(id: request.id, fingerprint: request.fingerprint, sessionID: request.sessionID,
                logicalID: request.logicalID, createdAt: now, expiresAt: request.expiresAt)
        if saved == nil {
            if let logicalID = request.logicalID, let previous = try store.claudeHook(logicalID: logicalID), previous.expiresAt > now {
                // PreToolUse -> PermissionRequest is the same tool call, not another approval.
                if previous.audit?.outcome.hasPrefix("시스템 변경 거절") == true,
                   let message = previous.audit?.answer, let event = payload["hook_event_name"] as? String {
                    let response = SystemCommandRisk.denial(event: event, message: message)
                    receipt.response = String(decoding: try JSONSerialization.data(withJSONObject: response), as: UTF8.self)
                    try saveClaudeReceipt(receipt)
                    return bridgeResponse(response)
                }
                receipt.response = "{}"
                try saveClaudeReceipt(receipt)
                return bridgeResponse([:])
            }
        }
        // Claude's computer use moves the real pointer and activates apps. While the guard is on, those calls
        // are denied with directions to the background desktop tools, so the user's focus is never taken.
        if envelope.event == "PreToolUse",
           let message = ClaudeComputerUseRedirect.denial(tool: request.tool, input: payload["tool_input"] as? JSONObject ?? [:]),
           backgroundComputerUseGuard {
            let response = SystemCommandRisk.denial(event: envelope.event, message: message)
            receipt.response = String(decoding: try JSONSerialization.data(withJSONObject: response), as: UTF8.self)
            try saveClaudeReceipt(receipt)
            log(AuditEvent(sessionID: request.sessionID, summary: request.summary, outcome: "포커스 보호 · 백그라운드 조작 안내",
                           source: "Claude 훅", tool: request.tool))
            publish()
            return bridgeResponse(response)
        }
        // A worker on a group task never waits for a person. A question AutoApprove cannot answer at once
        // is returned, so the worker ends its turn and the question reaches the assigning member as a report.
        if request.isQuestion, ["PreToolUse", "PermissionRequest"].contains(envelope.event),
           !holdsClaudeHook(request, questionEditing: false),
           (try? groupOrchestration())?.assignments.contains(where: { $0.workerSessionID == request.sessionID && $0.status == .working }) == true {
            let response = SystemCommandRisk.denial(event: envelope.event, message: SessionGroupOrchestration.questionRedirect)
            receipt.response = String(decoding: try JSONSerialization.data(withJSONObject: response), as: UTF8.self)
            try saveClaudeReceipt(receipt)
            log(AuditEvent(sessionID: request.sessionID, summary: request.summary, outcome: "그룹 작업 질문 반환",
                           source: "세션 그룹", tool: request.tool))
            publish()
            return bridgeResponse(response)
        }
        if !holdsClaudeHook(request, questionEditing: false) {
            invalidateClaudeHooks(for: payload, sessionID: request.sessionID)
            let response = handleHook(request.payload, deferApproval: false, prepared: request)
            receipt.response = String(decoding: try JSONSerialization.data(withJSONObject: response), as: UTF8.self)
            try saveClaudeReceipt(receipt)
            return bridgeResponse(response)
        }
        if liveClaudeHooks[request.id] == nil {
            _ = handleHook(request.payload, deferApproval: true, prepared: request)
            // Never offer a button for a guessed process or an already-ended session.
            guard sessions[request.sessionID]?.phase != .ended,
                  records.contains(where: { $0.key == request.sessionID && $0.agent == .claude }) else {
                receipt.response = "{}"; try saveClaudeReceipt(receipt)
                return bridgeResponse([:])
            }
            try saveClaudeReceipt(receipt)
        }
        let pending = LiveClaudeHook(request: request, receipt: receipt, lastContact: now,
            questionEditing: store.value("claudeQuestionEditing:" + request.id) == "true")
        liveClaudeHooks[request.id] = pending
        try answerClaudeHookIfEligible(pending, at: now)
        if let response = liveClaudeHooks[request.id]?.receipt.response {
            removeLiveClaudeHook(request.id)
            publish()
            return bridgeResponse((try JSONSerialization.jsonObject(with: Data(response.utf8))) as? JSONObject ?? [:])
        }
        publish()
        return bridgeResponse()
    }

    private func answerClaudeHookIfEligible(_ pending: LiveClaudeHook, at now: Date) throws {
        if pending.request.safetyResponse != nil, effectiveAutomatic(pending.request.sessionID), !snapshot.paused {
            try answerClaudeApproval(sessionID: pending.request.sessionID, requestID: pending.request.id, automatically: true, at: now)
        } else if pending.request.response != nil, !pending.questionEditing,
                  now.timeIntervalSince(pending.receipt.createdAt) >= confirmationDelay,
                  effectiveAutomatic(pending.request.sessionID), !snapshot.paused {
            try answerClaudeApproval(sessionID: pending.request.sessionID, requestID: pending.request.id, automatically: true, at: now)
        }
    }

    /// Keep the helper's existing socket waiting for its exact saved response.
    /// Fifteen-second heartbeats retain reconnect/expiry checks without 400ms
    /// polling. The original confirmation deadline wakes the wait precisely.
    private func waitForClaudeHook(_ payload: JSONObject) async throws -> JSONObject {
        guard payload["autoapproveProtocol"] as? Int == 1 else { throw AppError.message("지원하는 Claude 응답 프로토콜이 필요합니다.") }
        guard let envelope = ClaudeHookEnvelope(payload, at: Date()) else { return bridgeResponse([:]) }
        let id = envelope.id
        let result = try handleClaudeHook(envelope, at: Date())
        guard
              (result["autoapproveBridge"] as? JSONObject)?["waiting"] as? Bool == true,
              liveClaudeHooks[id] != nil else { return result }
        let signal = claudeHookSignals[id] ?? RemoteTerminalChangeSignal(); claudeHookSignals[id] = signal
        let observation = signal.observe(), epoch = observationEpoch, heartbeat = Date().addingTimeInterval(15)
        let automationEpoch = automationRuntime.epoch(envelope.sessionID)
        await observation.waitForChange(timeout: 0)
        while !Task.isCancelled, !remoteInputStopped, observationEpoch == epoch {
            guard automationRuntime.epoch(envelope.sessionID) == automationEpoch else { return bridgeResponse() }
            guard let pending = liveClaudeHooks[id] else { return try handleClaudeHook(envelope, at: Date()) }
            if pending.receipt.response != nil { return try handleClaudeHook(envelope, at: Date()) }
            let now = Date()
            guard pending.receipt.expiresAt > now else { return bridgeResponse([:]) }
            var interval = min(heartbeat, pending.receipt.expiresAt).timeIntervalSince(now)
            if pending.request.response != nil, !snapshot.paused, effectiveAutomatic(pending.request.sessionID),
               !pending.questionEditing {
                let untilConfirmation = pending.receipt.createdAt.addingTimeInterval(confirmationDelay).timeIntervalSinceNow
                if untilConfirmation > 0 { interval = min(interval, untilConfirmation) }
            }
            await observation.waitForChange(timeout: interval)
            guard !Task.isCancelled, !remoteInputStopped, observationEpoch == epoch,
                  automationRuntime.epoch(envelope.sessionID) == automationEpoch else { return bridgeResponse() }
            let resumedAt = Date()
            guard let current = liveClaudeHooks[id] else { return try handleClaudeHook(envelope, at: resumedAt) }
            if current.receipt.response != nil { return try handleClaudeHook(envelope, at: resumedAt) }
            guard current.receipt.expiresAt > resumedAt else { return bridgeResponse([:]) }
            try answerClaudeHookIfEligible(current, at: resumedAt)
            if liveClaudeHooks[id]?.receipt.response != nil { return try handleClaudeHook(envelope, at: resumedAt) }
            if resumedAt >= heartbeat { return result }
        }
        return bridgeResponse()
    }

    public func answerClaudeApproval(sessionID: String, requestID: String, enableAutomatic: Bool = false, automatically: Bool = false, at now: Date = Date()) throws {
        guard let pending = liveClaudeHooks[requestID], pending.request.sessionID == sessionID,
              pending.receipt.response == nil, pending.receipt.expiresAt > now,
              now.timeIntervalSince(pending.lastContact) < 25, let defaultResponse = pending.request.safetyResponse ?? pending.request.response else {
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
        let risk = pending.request.systemCommandRisk ?? SystemCommandRisk.detect(tool: pending.request.tool,
            input: pending.request.payload["tool_input"] as? JSONObject ?? [:], summary: pending.request.summary, cwd: sessions[sessionID]?.cwd ?? "")
        let response = risk?.denial(event: pending.request.payload["hook_event_name"] as? String ?? "PermissionRequest") ?? defaultResponse
        if enableAutomatic, risk == nil { try setAutomatic(sessionID, enabled: true) }
        var receipt = pending.receipt
        receipt.response = String(decoding: try JSONSerialization.data(withJSONObject: response), as: UTF8.self)
        receipt.audit = contextualEvent(AuditEvent(sessionID: sessionID, summary: pending.request.summary,
            outcome: risk != nil ? "시스템 변경 거절 · 안전한 대안 안내 대기열 등록" : "답변 대기열 등록", source: "Claude 훅", tool: pending.request.tool,
            request: pending.request.inputJSON, answer: risk?.guidance ?? pending.request.answer))
        try saveClaudeReceipt(receipt)
        liveClaudeHooks[requestID]?.receipt = receipt
        if let risk {
            var notice = sessions[sessionID]?.systemSafety ?? SystemSafetyNotice(id: requestID, risk: risk, request: pending.request.summary, at: now)
            notice.phase = .submitting; notice.message = "Claude에 거절 이유와 안전한 대안 안내를 전달하고 있습니다…"; notice.updatedAt = now
            try saveSystemSafety(sessionID, SystemSafetyState(notice: notice, hookRequestID: requestID))
        }
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

    public func replyClaudeQuestions(sessionID: String, requestID: String, answers: Any?, at now: Date = Date()) throws {
        guard let pending = liveClaudeHooks[requestID], pending.request.sessionID == sessionID,
              pending.request.systemCommandRisk == nil,
              pending.receipt.response == nil, pending.receipt.expiresAt > now,
              now.timeIntervalSince(pending.lastContact) < 25, let fields = pending.request.questions else {
            throw RemoteHTTPError(409, "질문이 이미 처리되었거나 Claude 연결이 끝났습니다.")
        }
        let values = try WebQuestionField.answers(answers, for: fields)
        let current = try processReader()
        guard current.contains(where: { $0.key == sessionID && $0.agent == .claude }) else { throw RemoteHTTPError(409, "질문을 보낸 Claude 실행이 종료되었습니다.") }
        updateDiscovery(ProcessDiscovery.sessions(current), records: current)
        guard sessions[sessionID]?.phase != .ended, liveClaudeHooks[requestID]?.receipt.response == nil else { throw RemoteHTTPError(409, "질문 상태가 변경되었습니다.") }
        var input = pending.request.payload["tool_input"] as? JSONObject ?? [:]
        input["answers"] = values
        let event = pending.request.payload["hook_event_name"] as? String ?? "PreToolUse"
        let response: JSONObject = ["hookSpecificOutput": event == "PreToolUse"
            ? ["hookEventName": event, "permissionDecision": "allow", "updatedInput": input]
            : ["hookEventName": event, "decision": ["behavior": "allow", "updatedInput": input]]]
        var receipt = pending.receipt
        receipt.response = String(decoding: try JSONSerialization.data(withJSONObject: response), as: UTF8.self)
        receipt.audit = contextualEvent(AuditEvent(sessionID: sessionID, summary: pending.request.summary,
            outcome: "답변 대기열 등록", source: "Claude 질문 웹 폼", tool: "AskUserQuestion", request: pending.request.inputJSON,
            answer: fields.map { "\($0.question): \(values[$0.question]!)" }.joined(separator: "\n\n")))
        try saveClaudeReceipt(receipt)
        liveClaudeHooks[requestID]?.receipt = receipt; claudeHookObservedAt[sessionID] = now; publish()
    }

    public func acknowledgeClaudeHook(_ payload: JSONObject, at now: Date = Date()) throws {
        guard let request = ClaudeHookEnvelope(payload, at: now), var receipt = try store.claudeHook(id: request.id),
              receipt.fingerprint == request.fingerprint, receipt.response != nil, !receipt.acknowledged else { return }
        receipt.acknowledged = true
        if receipt.audit?.outcome == "답변 대기열 등록" {
            receipt.audit?.outcome = request.isQuestion ? "질문 응답 전달" : "승인 전달"
        } else if receipt.audit?.outcome == "시스템 변경 거절 · 안전한 대안 안내 대기열 등록" {
            receipt.audit?.outcome = "시스템 변경 거절 · 안전한 대안 안내 전달 확인"
        }
        try saveClaudeReceipt(receipt)
        if receipt.audit?.outcome == "시스템 변경 거절 · 안전한 대안 안내 전달 확인",
           var state = systemSafetyStates[request.sessionID], state.generation == nil, state.hookRequestID == request.id {
            state.notice.phase = .guided; state.notice.message = "시스템 변경을 거절하고 같은 Claude 대화에 안전한 대안을 전달했습니다."; state.notice.updatedAt = now
            try saveSystemSafety(request.sessionID, state)
        }
        removeLiveClaudeHook(request.id)
        publish()
    }

    private func removeLiveClaudeHook(_ id: String, terminal: Bool = false) {
        claudeHookSignals.removeValue(forKey: id)?.notify()
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
            sessions[key]?.systemCommandRisk = nil
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
        // Group once instead of scanning every live hook for each discovered
        // session on every screen publication.
        let approvalsBySession = Dictionary(grouping: liveClaudeHooks.values, by: { $0.request.sessionID })
        var projectedIDs = projectedClaudeApprovalSessionIDs
        projectedIDs.formUnion(approvalsBySession.keys)
        for id in projectedIDs {
            guard sessions[id] != nil else {
                projectedClaudeApprovalSessionIDs.remove(id)
                continue
            }
            guard let sessionApprovals = approvalsBySession[id], !sessionApprovals.isEmpty else {
                if sessions[id]?.claudeApprovals != nil { sessions[id]?.claudeApprovals = nil }
                projectedClaudeApprovalSessionIDs.remove(id)
                continue
            }
            projectedClaudeApprovalSessionIDs.insert(id)
            let pending = sessionApprovals.sorted { $0.receipt.createdAt < $1.receipt.createdAt }
            let automatic = effectiveAutomatic(id) && !snapshot.paused
            sessions[id]?.claudeApprovals = pending.isEmpty ? nil : pending.map { item in
                let risk = item.request.systemCommandRisk
                return ClaudeApproval(id: item.request.id, summary: item.request.summary, answer: item.request.answer,
                    isQuestion: item.request.isQuestion, sending: item.receipt.response != nil, expiresAt: item.receipt.expiresAt,
                    automaticAt: automatic && risk == nil && item.request.response != nil && !item.questionEditing ? item.receipt.createdAt.addingTimeInterval(confirmationDelay) : nil,
                    questions: item.request.questions, systemCommandRisk: risk)
            }
            if let first = pending.first, sessions[id]?.phase != .ended {
                sessions[id]?.pendingSummary = first.request.summary
                sessions[id]?.pendingRequestID = "bridge:" + first.request.id
                sessions[id]?.pendingInTerminal = true
                let detail = first.receipt.response != nil ? "Claude에 응답을 전달하는 중입니다…" : first.request.systemCommandRisk?.detail ?? "AutoApprove에서 이번 요청을 허용할 수 있습니다."
                sessions[id]?.setPhase(first.request.isQuestion ? .input : .approval, detail: detail)
            }
        }
    }

    private func receive(_ message: JSONObject, from peer: SocketConnection) {
        let method = message["method"] as? String ?? ""
        let params = message["params"] as? JSONObject ?? [:]
        if method == "hookWait" {
            guard claudeHookWaitTasks[peer.id] == nil else { _ = peer.send(["error": "이 연결에는 이미 대기 중인 응답이 있습니다."]); return }
            let token = UUID()
            let task = Task { @MainActor [weak self] in
                guard let self else { return }
                var response: JSONObject
                do { response = ["result": try await self.waitForClaudeHook(params)] }
                catch { response = ["error": error.localizedDescription] }
                guard !Task.isCancelled, self.claudeHookWaitTasks[peer.id]?.token == token else { return }
                self.claudeHookWaitTasks.removeValue(forKey: peer.id)
                if let id = message["id"] { response["id"] = id }
                _ = peer.send(response)
            }
            claudeHookWaitTasks[peer.id] = (token, task)
            return
        }
        if method == "codexAccountInspection" {
            Task { @MainActor [weak self] in
                guard let self else{return}
                var response:JSONObject
                do {response=["result":try await self.inspectCodexAccount(home:params["home"] as? String ?? NSHomeDirectory()+"/.codex").json]}
                catch {response=["error":error.localizedDescription]}
                if let id=message["id"] {response["id"]=id};_ = peer.send(response)
            }
            return
        }
        if method == "diagnostics" {
            Task { @MainActor [weak self] in
                guard let self else{return}
                var response:JSONObject=["result":await self.diagnostics()]
                if let id=message["id"] {response["id"]=id}
                _ = peer.send(response)
            }
            return
        }
        if method == "mcp" {
            Task { @MainActor [weak self] in
                guard let self else { return }
                var response: JSONObject
                do { response = ["result": try await self.mcpAction(params)] }
                catch { response = ["error": error.localizedDescription] }
                if let id = message["id"] { response["id"] = id }
                _ = peer.send(response)
            }
            return
        }
        var result: JSONObject = [:]
        do {
            switch method {
            case "status": result = try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? JSONObject ?? [:]
            case "updateHealth":
                result = ["nodeID": try installationNodeID(), "pid": Int(getpid())]
                if let release = RemoteWebVersion.current { result["release"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(release)) }
            case "terminalTimings": result = try JSONSerialization.jsonObject(with:JSONEncoder().encode(RemoteTerminalPerformance.shared.snapshot())) as? JSONObject ?? [:]
            case "pause": try setPaused(params["paused"] as? Bool ?? true); result = ["paused": snapshot.paused]
            case "automatic":
                guard let id = params["sessionID"] as? String, let enabled = params["enabled"] as? Bool else { throw AppError.message("세션 ID와 설정값이 필요합니다.") }
                try setAutomatic(id, enabled: enabled); result = ["enabled": enabled]
            case "restart":
                // The same request as the session window's context menu, for one named session.
                guard let id = params["sessionID"] as? String, let session = sessions[id], session.phase != .ended,
                      session.agent != .shell else { throw AppError.message("실행 중인 에이전트 세션 ID가 필요합니다.") }
                let progress = restartSessions([id], resume: params["resume"] as? Bool ?? true)
                result = try JSONSerialization.jsonObject(with: JSONEncoder().encode(progress)) as? JSONObject ?? [:]
            case "web":
                if let enabled = params["enabled"] as? Bool {
                    let port = (params["port"] as? Int).flatMap(UInt16.init(exactly:))
                    try setWebEnabled(enabled, port: port)
                }
                result = try JSONSerialization.jsonObject(with: JSONEncoder().encode(webStatus)) as? JSONObject ?? [:]
            case "isolation":
                if let enabled = params["enabled"] as? Bool { try setNetworkIsolation(enabled) }
                result = ["enabled": networkIsolated]
            case "agyHook":
                guard let pid = peer.processID, let agent = try ProcessDiscovery.enclosingAgent(of: pid),
                      agent.agent == .agy, agent.tty != "??" else { throw AppError.message("agy 터미널을 확인할 수 없습니다.") }
                let event = try JSONDecoder().decode(AgyHookRequest.self, from: JSONSerialization.data(withJSONObject: params))
                guard UUID(uuidString: event.conversationId) != nil else { throw AppError.message("agy 대화 ID를 확인할 수 없습니다.") }
                let state = AgyState(conversationId: event.conversationId.lowercased(), isIdle: event.isIdle, modelName: event.modelName)
                agyEvents[agent.key] = state
                if var session = sessions[agent.key], session.phase != .ended {
                    applyAgyState(state, to: &session)
                    sessions[agent.key] = session
                    if event.hookEventName == .stop, state.isIdle {
                        scheduleGroupMailboxDelivery()
                        if event.terminationReason == "NO_TOOL_CALL", let path = event.transcriptPath,
                           let groups = try? SessionGroupStore(directory: paths.directory).load(),
                           groups.contains(where: { group in group.members.contains { $0.agent == .agy && $0.conversationID.lowercased() == state.conversationId } }),
                           let turn = AgyTranscript.finalTurn(path: path, conversation: state.conversationId) {
                            let id = state.conversationId + ":" + String(turn.step)
                            receiveGroupTurn(conversation: state.conversationId, turn: id, prompt: turn.prompt, response: turn.answer)
                            noteGroupCompletion(agent.key, WorkCompletion(id: id, date: turn.date, summary: turn.answer),
                                                conversation: state.conversationId, prompt: turn.prompt, turn: id)
                        }
                    }
                    publish()
                }
                if event.hookEventName == .preToolUse {
                    if let command = event.toolCall?.commandLine, let risk = SystemCommandRisk.detect(command) {
                        result = ["decision":"deny","reason":risk.detail]
                    } else if sessions[agent.key]?.automatic == true, !snapshot.paused, event.toolCall?.name == "read_file" {
                        result = ["decision":"allow"]
                    } else { result = ["decision":"ask"] }
                }
            case "desktopGuard":
                if let enabled = params["enabled"] as? Bool { try setBackgroundComputerUseGuard(enabled) }
                result = ["enabled": backgroundComputerUseGuard]
            case "hook": result = params["autoapproveProtocol"] as? Int == 1 ? try handleClaudeHook(params) : handleHook(params)
            case "hookAck": try acknowledgeClaudeHook(params)
            case "claudeApprove":
                guard let id = params["sessionID"] as? String, let request = params["requestID"] as? String else { throw AppError.message("세션과 요청 ID가 필요합니다.") }
                try answerClaudeApproval(sessionID: id, requestID: request, enableAutomatic: params["enableAutomatic"] as? Bool ?? false,
                    at: Date())
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
                    scheduleScreenApproval(action.sessionID)
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
        claudeHookWaitTasks.removeValue(forKey: peerID)?.task.cancel()
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

    private func clearScreen(_ id: String, keepRemote: Bool = false) {
        cancelModelRetention(id)
        if sessions[id] == nil || sessions[id]?.phase == .ended {
            manuallyChangedModelQuestions.removeValue(forKey: id); retainedModelMenus.removeValue(forKey: id)
        }
        remoteMonitorFrames.removeValue(forKey: id)
        // A failed background monitor clears approval observations, not the
        // independent exact-target web stream. Its frames still expire and
        // every input validates the original process, TTY and foreground job.
        if !keepRemote {
            cancelRemoteInitialRead(id)
            remoteObservedScreens.removeValue(forKey: id); remoteFrames.removeValue(forKey: id); remoteScreenReads.removeValue(forKey: id)?.task.cancel()
        }
        remoteTerminalChanges[id]?.notify()
        if sessions[id] == nil || sessions[id]?.phase == .ended { remoteOrcaBindings.removeValue(forKey: id); remoteTerminalChanges.removeValue(forKey:id) }
        screens.removeValue(forKey: id); activityTrackers.removeValue(forKey: id); screenObservedAt.removeValue(forKey: id)
        removeScreenAnalysis(id)
        sessions[id]?.pendingSummary = nil; sessions[id]?.pendingInTerminal = false
        sessions[id]?.pendingRequestID = nil
        sessions[id]?.systemCommandRisk = nil
    }

    private func removeScreenAnalysis(_ sessionID: String) {
        if let analysis = screenAnalyses.removeValue(forKey: sessionID) {
            screenAnalysisCacheBytes = max(0, screenAnalysisCacheBytes - analysis.sourceByteCount)
        }
    }

    private func pruneExpiredRemoteFrames() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now >= nextRemoteFramePruneAt else { return }
        nextRemoteFramePruneAt = now + 1
        guard !remoteFrames.isEmpty || !remoteScreenReads.isEmpty else { return }
        let date = Date()
        // A completed Task retains its full source output even after the frame
        // expires. Keep the existing reuse window, but do not pin visited
        // sessions indefinitely or evict a result another waiter still owns.
        let expiredReads = remoteScreenReads.compactMap { id, read in
            read.activeReaders == 0 && read.observedAt.map({ date.timeIntervalSince($0) >= Self.remoteReadCacheLifetime }) == true ? id : nil
        }
        for id in expiredReads { remoteScreenReads.removeValue(forKey: id) }
        let expired = remoteFrames.compactMap { id, value in
            date.timeIntervalSince(value.frame.observedAt) >= 10 ? id : nil
        }
        for id in expired { remoteFrames.removeValue(forKey: id) }
    }

    public func receiveScreen(sessionID: String, raw: String, generation: String, source: ApprovalChannel? = nil, at now: Date = Date(), appearance: TerminalAppearance? = nil, cursor: TerminalCursor? = nil, display: TerminalTextSnapshot? = nil) {
        receiveScreen(sessionID: sessionID, raw: raw, generation: generation, source: source, at: now, appearance: appearance, cursor: cursor, display: display, precomputed: nil, screenContentsUnchanged: false)
    }

    private func receiveScreen(sessionID: String, raw: String, generation: String, source: ApprovalChannel? = nil, at now: Date = Date(), appearance: TerminalAppearance? = nil, cursor: TerminalCursor? = nil, display: TerminalTextSnapshot? = nil, precomputed: ScreenAnalysis?, screenContentsUnchanged: Bool) {
        guard let session = sessions[sessionID], session.agent != .shell, session.phase != .ended else { return }
        automationNeedsFreshScreen.remove(sessionID)
        let previousFrame = remoteObservedScreens[sessionID]
        if session.agent == .codex,
           groupStatusIdentities[sessionID] != nil || groupMCPIdentities.values.contains(where: { $0.runtimeID == sessionID }),
           !screenContentsUnchanged, raw.contains(">_ OpenAI Codex (v"),
           !ScreenTextEquality.identical(previousFrame?.raw, raw),
           CodexStatusIdentity.isWelcomeReset(raw) {
            // A reset can retain its PID. Historical brand headers in ordinary
            // work output must not erase a previously verified conversation.
            groupStatusIdentities.removeValue(forKey: sessionID)
            discardGroupMCPIdentities(for: sessionID)
        }
        // Registration and frame updates share this actor. A new observer starts
        // pending and reads the latest frame; an empty signal has no callback.
        // Avoid comparing a long Cocoa screen when nobody can use its notice.
        if remoteTerminalChanges[sessionID]?.hasObservers == true {
            if (!screenContentsUnchanged && !ScreenTextEquality.equal(previousFrame?.raw, raw)) || previousFrame?.generation != generation || previousFrame?.cursor != cursor || previousFrame?.appearance != appearance || previousFrame?.display != display { remoteTerminalChanges[sessionID]?.notify() }
        }
        remoteObservedScreens[sessionID] = RemoteObservedScreen(raw: raw, generation: generation, observedAt: now, appearance: appearance?.validated(for: raw), cursor: cursor?.validated(for: raw), display: display?.validated())
        if session.agent == .agy { return }
        // The original hook is still waiting in this app; screen input would be a second response path.
        guard !liveClaudeHooks.values.contains(where: { $0.request.sessionID == sessionID }) else { return }
        // A parked main terminal renders the child PTY. Its pixels cannot identify
        // which child owns the prompt; the child's hook is the response channel.
        guard !hasBackgroundChildren(sessionID), claudeParents[sessionID] == nil else { return }
        let analysis: ScreenAnalysis
        if let precomputed { analysis = precomputed }
        else if let cached = screenAnalyses[sessionID], cached.agent == session.agent,
                let previousFrame, ScreenTextEquality.identical(previousFrame.raw, raw) { analysis = cached }
        else {
            analysis = ScreenAnalysis(raw: raw, agent: session.agent)
        }
        removeScreenAnalysis(sessionID)
        // Keep repeated large scrollbacks cheap without allowing the analysis cache
        // to grow with session count or retain one unbounded screen per session.
        let screenBytes = analysis.sourceByteCount
        if screenBytes <= screenAnalysisCacheScreenLimit,
           screenAnalyses.count < 32,
           screenAnalysisCacheBytes + screenBytes <= screenAnalysisCacheTotalLimit {
            screenAnalyses[sessionID] = analysis
            screenAnalysisCacheBytes += screenBytes
        }
        let sessionBeforeScreen = session
        let capacityBeforeScreen = capacityResumeProjection(for: sessionID)
        observeCapacity(sessionID,analysis:analysis,raw:raw,at:now)
        defer {
            scheduleSystemSafety(sessionID)
            observeCodexProgress(sessionID,raw:raw,generation:generation,at:now)
            // Native screen polling can deliver the same frame every 1–2 s.
            // Keep freshness and detector state current, but don't rebuild all
            // question, inbox and session projections unless this observation
            // changed something the UI can see.
            // Compare the unwrapped value directly, keeping every session field
            // in equality without promoting another 1 KiB value to Optional.
            let sessionChanged: Bool
            if let current = sessions[sessionID] {
                sessionChanged = current != sessionBeforeScreen
            } else {
                sessionChanged = true
            }
            if sessionChanged || capacityResumeProjection(for: sessionID) != capacityBeforeScreen {
                publish()
            }
        }
        if analysis.capacityStop != nil {
            sessions[sessionID]?.systemCommandRisk = nil
            // An error's empty composer accepts text, not the numeric permission answer.
            // Retire a previously queued approval before its asynchronous process check returns.
            screens.removeValue(forKey:sessionID)
            sessions[sessionID]?.pendingSummary = nil; sessions[sessionID]?.pendingInTerminal = false
            sessions[sessionID]?.pendingRequestID = nil
            activityTrackers.removeValue(forKey:sessionID)
            presentPhase(sessionID,analysis.activity,at:now)
            return
        }
        let prompt = analysis.prompt
        if let receipt = resetApprovalReceipts[sessionID],
           receipt.generation != generation || prompt.map({ $0.requestIdentity != receipt.requestIdentity && $0.hasRequestBoundary }) == true ||
           (prompt == nil && [.working, .idle, .input].contains(analysis.activity.phase)) {
            resetApprovalReceipts.removeValue(forKey: sessionID)
        }
        if session.channel == .hook {
            // A hook that already allowed the request must never be followed by a screen approval.
            // A released hook returns `{}` and leaves its request pending in the terminal, so the screen may answer it.
            // Ownership stays with the kind of request that was released: a question takes only a choice screen,
            // and a permission request takes only a permission dialog.
            let matchesReleasedRequest = session.phase == .input
                ? prompt == nil && analysis.request?.phase == .input
                : session.phase == .approval && prompt != nil
            guard matchesReleasedRequest, session.pendingInTerminal, let source, source.isScreen else { return }
            sessions[sessionID]?.channel = source
        } else if !session.channel.isScreen { return }
        screenObservedAt[sessionID] = now
        reconcileModelRetention(sessionID, choice: analysis.modelChoice, generation: generation,
            resolved: analysis.request == nil && (analysis.activity.phase == .working || analysis.activity.phase == .idle))
        guard let prompt else {
            sessions[sessionID]?.systemCommandRisk = nil
            let request = analysis.request
            let observation = analysis.activity
            let dispatched = screens[sessionID].map {$0.generation == generation && $0.attempted} == true
            // An incomplete repaint is not evidence that a dispatched request finished.
            // Keep its reservation, but never dispatch from this unverified frame.
            if dispatched && observation.phase != .working ||
                screens[sessionID]?.generation == generation && request?.phase != .input &&
                (observation.phase == .unknown || request?.phase == .approval) {
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
            let activity = activityTrackers[sessionID, default: ActivityTracker()].observe(observation, fingerprint: analysis.fingerprint, agent: session.agent, generation: generation, at: now)
            presentPhase(sessionID, activity, at: now)
            // A draft, blank repaint or selection is not proof that an already
            // answered permission is a new request. Only real work or a stable
            // empty composer can retire its single-use dispatch reservation.
            if dispatched,activity.phase == .idle,!userInputHasPriority(sessionID) {screens.removeValue(forKey:sessionID)}
            return
        }
        activityTrackers.removeValue(forKey: sessionID)
        let risk = Self.screenApprovalRisk(prompt,agent:session.agent,cwd:session.cwd)
        sessions[sessionID]?.systemCommandRisk = risk
        if let risk { observeSystemSafety(sessionID, risk: risk, prompt: prompt, generation: generation, at: now) }
        if let existing = screens[sessionID], existing.isCurrent, existing.generation == generation, existing.prompt.identity == prompt.identity {
            screens[sessionID]?.raw = raw; screens[sessionID]?.prompt = prompt
            if let risk { screens[sessionID]?.scheduledID = nil; sessions[sessionID]?.pendingInTerminal = true; sessions[sessionID]?.activityDetail = risk.detail }
            scheduleScreenApproval(sessionID)
            return
        }
        // A CLI can replace one permission dialog with the next between screen polls.
        // A new command must not inherit the preceding command's single-use reservation.
        // Formatting or choice-hint changes alone still cannot replay a sent input.
        let previous = screens[sessionID].flatMap {
            $0.generation == generation && ($0.prompt.requestIdentity == prompt.requestIdentity
                || !($0.prompt.hasRequestBoundary && prompt.hasRequestBoundary)) ? $0 : nil
        }
        var current = previous ?? ScreenState(raw: raw, prompt: prompt, generation: generation)
        if let receipt = resetApprovalReceipts[sessionID], receipt.generation == generation,
           receipt.requestIdentity == prompt.requestIdentity || !prompt.hasRequestBoundary {
            current.attempted = true
            current.reviewDetail = "초기화 전에 전달 중이던 입력의 결과를 확인해주세요. 같은 요청에는 자동으로 중복 입력하지 않습니다."
        }
        // Coalesce render changes while process validation is in flight. The adapter
        // still receives the latest complete original dialog for its final check.
        if current.prompt.requestIdentity != prompt.requestIdentity { current.scheduledID = nil }
        current.raw = raw; current.prompt = prompt; current.isCurrent = true
        screens[sessionID] = current
        sessions[sessionID]?.setPhase(.approval, detail: risk?.detail ?? current.reviewDetail ?? "터미널에서 실행 권한에 대한 응답을 기다리고 있습니다.", at: now)
        sessions[sessionID]?.pendingSummary = prompt.summary
        sessions[sessionID]?.pendingInTerminal = risk != nil || current.reviewDetail != nil
        sessions[sessionID]?.pendingRequestID = "screen:\(generation):\(prompt.requestIdentity)"
        sessions[sessionID]?.lastActivity = Date()
        scheduleScreenApproval(sessionID)
    }

    private func cancelModelRetention(_ id: String) {
        modelRetentionTasks.removeValue(forKey: id)?.task.cancel()
    }

    private func reconcileModelRetention(_ id: String, choice: TerminalChoiceQuestion?, generation: String, resolved: Bool) {
        let savedKey = "retainedModelMenu:" + id
        if retainedModelMenus[id] == nil { retainedModelMenus[id] = store.value(savedKey) ?? "" }
        guard let choice else {
            cancelModelRetention(id)
            if resolved {
                manuallyChangedModelQuestions.removeValue(forKey: id)
                if retainedModelMenus[id]?.isEmpty == false {
                    do { try store.set(savedKey, ""); retainedModelMenus[id] = "" } catch {}
                }
            }
            return
        }
        let identity = generation + ":" + choice.id
        let menuIdentity = PromptDetector.fingerprint(generation + "\n" + ([choice.question] + choice.options).map {
            $0.precomposedStringWithCanonicalMapping.filter { !$0.isWhitespace }
        }.joined(separator: "\n"))
        if let previous = manuallyChangedModelQuestions[id], previous != identity { manuallyChangedModelQuestions.removeValue(forKey: id) }
        if let pending = modelRetentionTasks[id] {
            if pending.questionID == choice.id, pending.generation == generation, pending.revision == revision { return }
            cancelModelRetention(id)
        }
        let receipt = "terminalChoice:\(id):\(choice.id)"
        guard !remoteInputStopped, !snapshot.paused, effectiveAutomatic(id),
              !hasOSPermissionWait(id),!automationNeedsFreshScreen.contains(id),
              retainedModelMenus[id] != menuIdentity,
              manuallyChangedModelQuestions[id] != identity,
              !userInputHasPriority(id), !automaticInputBusy(id),
              let session = sessions[id], session.phase != .ended, session.channel.isScreen,
              remoteInputReason(session) == nil,
              savedReply(receipt) == nil || savedReply(receipt)?.canRetry == true,
              let index = AutomaticQuestionDecision.currentModelIndex(question: choice.question, options: choice.options) else { return }
        let token = UUID(), scheduledRevision = revision, delay = confirmationDelay
        let task = Task { [weak self] in
            guard let self else { return }
            defer { if self.modelRetentionTasks[id]?.token == token { self.modelRetentionTasks.removeValue(forKey: id) } }
            var reserved = false
            do {
                try await Task.sleep(for: .seconds(delay))
                @MainActor func authorize() throws {
                    guard !Task.isCancelled, !self.hasOSPermissionWait(id),!self.remoteInputStopped, !self.snapshot.paused,
                          self.revision == scheduledRevision, self.effectiveAutomatic(id),
                          self.modelRetentionTasks[id]?.token == token,
                          self.remoteObservedScreens[id]?.generation == generation,
                          let current = self.sessions[id], current.phase != .ended,
                          current.pid == session.pid, current.started == session.started, current.tty == session.tty,
                          current.channel == session.channel, current.screenHandle == session.screenHandle,
                          current.bridgeID == session.bridgeID, current.terminalID == session.terminalID else { throw CancellationError() }
                }
                try authorize()
                guard !self.userInputHasPriority(id), !self.automaticInputBusy(id) else { return }
                let frame = try await self.remoteTerminal(sessionID: id, realtime: true)
                try authorize()
                guard let current = frame.question, current.id == choice.id, frame.inputReason == nil,
                      current.options.indices.contains(index), current.options[index] == choice.options[index],
                      AutomaticQuestionDecision.currentModelIndex(question: current.question, options: current.options) == index else { return }
                // Persist before dispatch. Scrollback changes or an app restart
                // cannot replay an uncertain answer to this same model menu.
                try self.store.set(savedKey, menuIdentity); self.retainedModelMenus[id] = menuIdentity; reserved = true
                _ = try await self.replyTerminalQuestion(session, object: ["questionID": choice.id, "revision": frame.revision, "choice": index],
                    automaticAuthorization: authorize)
            } catch {
                if reserved, (error as? RemoteHTTPError)?.diagnostics?["delivery"] == "not_started",
                   self.retainedModelMenus[id] == menuIdentity,
                   self.modelRetentionTasks[id] == nil || self.modelRetentionTasks[id]?.token == token {
                    do { try self.store.set(savedKey, ""); self.retainedModelMenus[id] = "" } catch {}
                }
                if !Task.isCancelled, !self.snapshot.paused, self.sessions[id]?.phase != .ended {
                    let detail = "현재 모델 유지 입력을 완료하지 못했습니다. " + String(error.localizedDescription.prefix(1000))
                    if self.sessions[id]?.activityDetail != detail { self.sessions[id]?.activityDetail = detail; self.publish() }
                }
            }
        }
        modelRetentionTasks[id] = ModelRetentionTask(token: token, questionID: choice.id, generation: generation, revision: revision, task: task)
    }

    // MARK: System changes: refuse the mutation, continue in the same conversation

    private func saveSystemSafety(_ id: String, _ state: SystemSafetyState) throws {
        try store.set("systemSafety:" + id, String(decoding: try JSONEncoder().encode(state), as: UTF8.self))
        systemSafetyStates[id] = state; sessions[id]?.systemSafety = state.notice
    }

    private func observeSystemSafety(_ id: String, risk: SystemCommandRisk, prompt: ApprovalPrompt, generation: String, at now: Date) {
        if systemSafetyStates[id] == nil, let saved = store.value("systemSafety:" + id),
           let state = try? JSONDecoder().decode(SystemSafetyState.self, from: Data(saved.utf8)) {
            systemSafetyStates[id] = state; sessions[id]?.systemSafety = state.notice
        }
        let previous = systemSafetyStates[id]
        if previous?.generation == generation, previous?.promptIdentity == prompt.requestIdentity,
           previous?.notice.phase != .guided { return }
        // Once guidance was visibly submitted, an identical new permission is
        // a new request. Fresh-screen checks still reject a stale monitor frame.
        let key = PromptDetector.fingerprint(id + "\n" + generation + "\n" + prompt.requestIdentity + "\n" + UUID().uuidString)
        let state = SystemSafetyState(notice: SystemSafetyNotice(id: key, risk: risk, request: prompt.summary, at: now),
            generation: generation, promptIdentity: prompt.requestIdentity)
        do {
            try saveSystemSafety(id, state)
            _ = log(AuditEvent(sessionID: id, summary: prompt.summary, outcome: "시스템 변경 감지 · 자동 승인 제외", source: "시스템 변경 보호",
                request: prompt.dialog, answer: risk.guidance))
        } catch {
            sessions[id]?.systemSafety = state.notice
            sessions[id]?.activityDetail = "보호 기록을 저장하지 못해 입력하지 않았습니다. " + error.localizedDescription
        }
    }

    private func scheduleSystemSafety(_ id: String) {
        guard !hasOSPermissionWait(id),let state = systemSafetyStates[id], state.generation != nil,
              state.notice.phase != .guided, state.notice.phase != .uncertain,
              state.retryAfter.map({ $0 > Date() }) != true,
              !remoteInputStopped, !snapshot.paused, effectiveAutomatic(id), !automationNeedsFreshScreen.contains(id),
              !userInputHasPriority(id), !automaticInputBusy(id),
              let session = sessions[id], session.phase != .ended, session.channel.isScreen,
              !liveClaudeHooks.values.contains(where: { $0.request.sessionID == id }) else { return }
        let token = UUID()
        systemSafetyTasks[id] = token
        automationRuntime.launch(id) { [weak self] epoch in
            guard let self, self.systemSafetyTasks[id] == token else { return }
            self.automaticInputSessions.insert(id)
            defer {
                self.automaticInputSessions.remove(id)
                if self.systemSafetyTasks[id] == token { self.systemSafetyTasks.removeValue(forKey: id) }
                self.publish(); self.scheduleSystemSafety(id); self.scheduleScreenApproval(id)
            }
            await self.dispatchSystemSafety(session, noticeID: state.notice.id, automationEpoch: epoch)
        }
    }

    private func safetyInputAllowed(_ original: AgentSession, noticeID: String, automationEpoch: UInt64) -> Bool {
        guard !hasOSPermissionWait(original.id),!Task.isCancelled, automationRuntime.epoch(original.id) == automationEpoch,
              !automationNeedsFreshScreen.contains(original.id),
              !remoteInputStopped, !snapshot.paused, effectiveAutomatic(original.id), !userInputHasPriority(original.id),
              let current = sessions[original.id], current.phase != .ended, current.pid == original.pid,
              current.started == original.started, current.tty == original.tty, current.channel == original.channel,
              current.terminal == original.terminal, current.screenHandle == original.screenHandle,
              current.bridgeID == original.bridgeID, current.terminalID == original.terminalID,
              systemSafetyStates[original.id]?.notice.id == noticeID else { return false }
        return true
    }

    private func safetyRead(_ original: AgentSession) async throws -> String {
        if let host = ScreenHost(channel: original.channel), let adapter = screenAdapters[host] {
            let target = ScreenTarget(tty: original.tty, handle: original.screenHandle, sourcePID: original.pid, sourceStarted: original.started)
            let snapshot = try await Task.detached { try adapter.readForValidation([target]) }.value
            guard let screen = snapshot.screens.first(where: { $0.tty == original.tty }) else { throw AppError.message("원본 화면 연결이 필요합니다.") }
            return screen.contents
        }
        guard let frame = remoteObservedScreens[original.id], Date().timeIntervalSince(frame.observedAt) < 6,
              frame.generation == systemSafetyStates[original.id]?.generation else { throw AppError.message("원본 편집기 화면을 기다리고 있습니다.") }
        return frame.raw
    }

    /// This path does not impersonate a user input or reopen a CLI. Every write
    /// rechecks the original foreground job and the exact current screen.
    private func safetyWrite(_ original: AgentSession, noticeID: String, automationEpoch: UInt64, expected: String, input: RemoteTerminalInput) async throws -> TerminalDelivery {
        let reader = processReader, live = try await Task.detached { try reader() }.value
        guard safetyInputAllowed(original, noticeID: noticeID, automationEpoch: automationEpoch),
              let process = live.first(where: { $0.pid == original.pid && $0.started == original.started && $0.agent == original.agent
                && "/dev/" + $0.tty == original.tty && $0.isForeground }) else { return .agentMissing }
        if let host = ScreenHost(channel: original.channel), let adapter = screenAdapters[host] {
            let job = live.filter { $0.tty == process.tty && $0.processGroup == process.processGroup }.map(\.pid)
            let target = ScreenTarget(tty: original.tty, handle: original.screenHandle, jobPIDs: job, sourcePID: original.pid,
                sourceStarted: original.started, sourceIdentity: original.terminal == .terminal ? terminalInputIdentity(original.pid) : nil)
            guard original.terminal != .terminal || target.sourceIdentity != nil else { return .missingTarget }
            let fresh = try await safetyRead(original)
            guard fresh == expected, safetyInputAllowed(original, noticeID: noticeID, automationEpoch: automationEpoch) else { return .screenChanged }
            return try await Task.detached {
                // Relay keys ordinarily tolerate output changes; safety actions don't.
                guard try adapter.readForValidation([target]).screens.first(where: { $0.tty == target.tty })?.contents == expected else { return TerminalDelivery.screenChanged }
                guard try reader().contains(where: { $0.pid == original.pid && $0.started == original.started && $0.agent == original.agent
                    && "/dev/" + $0.tty == original.tty && $0.isForeground }) else { return .agentMissing }
                return try adapter.input(target, expected, original.agent, input)
            }.value
        }
        guard let observed = remoteObservedScreens[original.id], observed.raw == expected,
              observed.generation == systemSafetyStates[original.id]?.generation,
              let peerID = original.bridgeID, let peer = peers[peerID], let terminalID = original.terminalID else { return .screenChanged }
        let actionID = UUID().uuidString
        let sent: Bool = try await withCheckedThrowingContinuation { continuation in
            remoteInputReplies[actionID] = (peerID, continuation)
            if !peer.send(["method": "remoteInput", "id": actionID, "terminalID": terminalID, "screen": expected,
                "generation": String(observed.generation.dropFirst(peerID.count + 1)), "kind": input.kind.rawValue, "text": input.text,
                "expiresAt": Date().addingTimeInterval(2).timeIntervalSince1970 * 1000]) {
                remoteInputReplies.removeValue(forKey: actionID)?.continuation.resume(returning: false); return
            }
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                self?.remoteInputReplies.removeValue(forKey: actionID)?.continuation.resume(throwing: AppError.message("원본 입력의 전달 결과를 확인하지 못했습니다."))
            }
        }
        return sent ? .sent : .screenChanged
    }

    private func dispatchSystemSafety(_ original: AgentSession, noticeID: String, automationEpoch: UInt64) async {
        let id = original.id, deadline = Date().addingTimeInterval(45)
        var wrote = false
        func update(_ phase: SystemSafetyNotice.Phase, _ message: String, retry: TimeInterval? = nil) throws {
            guard safetyInputAllowed(original, noticeID: noticeID, automationEpoch: automationEpoch),
                  var state = systemSafetyStates[id], state.notice.id == noticeID else { return }
            state.notice.phase = phase; state.notice.message = message; state.notice.updatedAt = Date()
            state.retryAfter = retry.map { Date().addingTimeInterval($0) }
            try saveSystemSafety(id, state); publish()
        }
        do {
            while safetyInputAllowed(original, noticeID: noticeID, automationEpoch: automationEpoch), var state = systemSafetyStates[id], Date() < deadline {
                let raw = try await safetyRead(original)
                guard safetyInputAllowed(original, noticeID: noticeID, automationEpoch: automationEpoch) else { return }
                switch state.notice.phase {
                case .guided, .uncertain: return
                case .cancelling:
                    // A crash while Escape was in flight cannot replay that key.
                    try update(.uncertain, "시스템 변경은 승인하지 않았습니다. 거절 결과를 확인하지 못해 입력을 반복하지 않습니다."); return
                case .detected,
                     .unavailable where state.cancelledAt == nil:
                    guard let prompt = PromptDetector.detect(raw, agent: original.agent), prompt.requestIdentity == state.promptIdentity,
                          SystemCommandRisk.detect(prompt.summary, cwd: original.cwd) != nil else {
                        try update(.uncertain, "원본 요청이 바뀌어 입력하지 않았습니다. 현재 대화에서 안전하게 진행해주세요."); return
                    }
                    try update(.cancelling, "이 시스템 변경 요청을 거절하고 있습니다…")
                    wrote = true
                    let result = try await safetyWrite(original, noticeID: noticeID, automationEpoch: automationEpoch, expected: raw, input: RemoteTerminalInput(kind: .escape))
                    wrote = false
                    guard safetyInputAllowed(original, noticeID: noticeID, automationEpoch: automationEpoch) else { return }
                    guard result == .sent else {
                        try update(.unavailable, "시스템 변경은 승인하지 않았습니다. 원본 직접 입력 연결을 확인하면 안전한 대안 안내를 다시 시도합니다.", retry: 5); return
                    }
                    state = systemSafetyStates[id]!
                    state.cancelledAt = Date(); state.notice.phase = .cancelled
                    state.notice.message = "요청을 거절했습니다. 같은 대화의 빈 입력창을 확인하고 있습니다…"
                    try saveSystemSafety(id, state)
                    _ = log(AuditEvent(sessionID: id, summary: state.notice.request, outcome: "시스템 변경 거절 입력 전달", source: "시스템 변경 보호", answer: "Escape"))
                case .cancelled, .unavailable:
                    if state.draft != nil {
                        try update(.typing, "이미 입력한 안내문의 전달 상태를 확인하고 있습니다…"); continue
                    }
                    guard Date().timeIntervalSince(state.cancelledAt ?? state.notice.date) < 30 else {
                        try update(.uncertain, "요청을 거절했지만 빈 입력창을 확인하지 못했습니다. 다른 입력을 덮어쓰지 않았습니다."); return
                    }
                    guard let composer = SystemSafetyComposer.capture(raw, agent: original.agent, text: state.notice.risk.guidance) else {
                        try await Task.sleep(nanoseconds: 250_000_000); continue
                    }
                    state.draft = composer; state.notice.phase = .typing; state.notice.message = "같은 원본 대화에 안전한 대안을 입력하고 있습니다…"
                    try saveSystemSafety(id, state); publish()
                    wrote = true
                    let result = try await safetyWrite(original, noticeID: noticeID, automationEpoch: automationEpoch, expected: raw,
                        input: RemoteTerminalInput(kind: .characters, text: composer.text))
                    wrote = false
                    guard safetyInputAllowed(original, noticeID: noticeID, automationEpoch: automationEpoch) else { return }
                    if result != .sent {
                        state = systemSafetyStates[id]!; state.draft = nil; try saveSystemSafety(id, state)
                        try update(.cancelled, "입력 전 화면이 바뀌어 대안 안내를 기다리고 있습니다.", retry: 2); return
                    }
                case .typing, .draft, .submitting:
                    guard let composer = state.draft else { try update(.uncertain, "안내문의 전달 상태를 확인하지 못해 입력을 반복하지 않습니다."); return }
                    if composer.submitted(raw) {
                        try update(.guided, "시스템 변경을 거절하고 같은 대화에 안전한 대안을 전달했습니다.")
                        _ = log(AuditEvent(sessionID: id, summary: state.notice.request, outcome: "안전한 대안 안내 전달 확인", source: "시스템 변경 보호", answer: composer.text)); return
                    }
                    guard composer.draftReady(raw) else { try await Task.sleep(nanoseconds: 250_000_000); continue }
                    guard state.submitAttempts < 3 else {
                        try update(.uncertain, "대안 안내문은 입력됐지만 전송을 확인하지 못했습니다. 원본 입력창의 Enter를 확인해주세요."); return
                    }
                    try await Task.sleep(nanoseconds: 750_000_000)
                    let fresh = try await safetyRead(original)
                    guard safetyInputAllowed(original, noticeID: noticeID, automationEpoch: automationEpoch) else { return }
                    guard composer.draftReady(fresh) else { continue }
                    state = systemSafetyStates[id]!
                    state.submitAttempts += 1; state.notice.phase = .submitting; state.notice.message = "안내문 전송을 확인하고 있습니다…"
                    try saveSystemSafety(id, state); publish()
                    wrote = true
                    let result = try await safetyWrite(original, noticeID: noticeID, automationEpoch: automationEpoch, expected: fresh, input: RemoteTerminalInput(kind: .enter, relay: true))
                    wrote = false
                    guard safetyInputAllowed(original, noticeID: noticeID, automationEpoch: automationEpoch) else { return }
                    if result != .sent { try update(.draft, "같은 안내문을 확인한 뒤 Enter만 다시 시도합니다.", retry: 2); return }
                    try await Task.sleep(nanoseconds: 750_000_000)
                }
            }
            guard safetyInputAllowed(original, noticeID: noticeID, automationEpoch: automationEpoch), let state = systemSafetyStates[id] else { return }
            if state.cancelledAt != nil && state.draft == nil {
                try update(.cancelled, "시스템 변경을 거절했습니다. 같은 대화의 빈 입력창을 기다리고 있습니다.", retry: 2)
            } else { try update(.uncertain, "대안 안내의 전달을 확인하지 못해 입력을 반복하지 않습니다. 원본 대화를 확인해주세요.") }
        } catch {
            let phase: SystemSafetyNotice.Phase = wrote ? .uncertain : .unavailable
            try? update(phase, "시스템 변경은 승인하지 않았습니다. " + String(error.localizedDescription.prefix(600)), retry: wrote ? nil : 5)
        }
    }

    // MARK: Codex capacity stops

    /// Answers a capacity stop only for a screen-connected Codex session with auto-approval on.
    /// After a confirmed send, the next stop drawn is the next failure of the same run.
    /// 0.2.78 recorded a Goal command's full original footer in the audit, but
    /// not in the receipt. Migrate only a draft bound to that exact saved run.
    private func restoreLegacyResumeDraft(_ id: String, raw: String) {
        guard let session = sessions[id], session.automatic, let receipt = session.interruption,
              receipt.resumeUncertain == true, receipt.resumeStop == nil,
              receipt.resumeSubmissionCancelled != true, receipt.kind == .goalBlocked,
              receipt.resumeCommand == CodexCapacityStop.goalResumeText,
              let key = receipt.resumeIdentity, key.hasPrefix("goal:"),
              CodexResumeCheck.draftVisible(raw, text: CodexCapacityStop.goalResumeText) else { return }
        let cacheKey = id + ":" + receipt.id + ":" + key
        if legacyResumeDraftReceipts[cacheKey] == nil {
            guard let events = try? store.history(search: id, limit: 32).events else { return }
            legacyResumeDraftReceipts[cacheKey] = events.compactMap { event in
                guard event.sessionID == id, event.answer == receipt.resumeCommand, let region = event.request else { return nil }
                let rows = PromptDetector.normalizedLines(region)
                guard CodexResumeCheck.goalStalled(rows), let composer = rows.lastIndex(where: CodexResumeCheck.isComposer) else { return nil }
                let identity = String(key.dropFirst("goal:".count))
                var stop = CodexCapacityStop(region: region, identity: identity)
                stop.continuationIdentity = identity; stop.kind = receipt.kind; stop.agent = session.agent
                stop.inputText = receipt.resumeCommand; stop.composerFooter = rows.dropFirst(composer + 1).joined(separator: "\n")
                return stop
            }
        }
        for stop in legacyResumeDraftReceipts[cacheKey] ?? [] {
            guard CodexResumeCheck.draftReady(raw, stop: stop) else { continue }
            sessions[id]?.interruption?.resumeStop = stop
            persistInterruption(id)
            return
        }
    }

    private func observeCapacity(_ id: String, analysis: ScreenAnalysis, raw: String, at now: Date) {
        restoreLegacyResumeDraft(id, raw: raw)
        guard let session = sessions[id], session.agent != .shell, session.phase != .ended else { return }
        // A newline is not a submitted continuation. An exact saved owned draft
        // can be completed later or after restart, without typing its text again.
        if session.automatic, session.interruption?.resumeUncertain == true,
           session.interruption?.resumeSubmissionCancelled != true,
           let saved = session.interruption?.resumeStop,
           session.interruption?.resumeIdentity == saved.continuationKey,
           session.interruption?.resumeCommand == saved.continuationText,
           CodexResumeCheck.draftReady(raw, stop: saved) {
            let channel = ScreenHost(kind:session.terminal).flatMap { screenConnections[$0]?.enabled == true ? $0.channel : nil } ?? session.channel
            let adapter = ScreenHost(channel:channel).flatMap { screenAdapters[$0] }
            if channel.isScreen, adapter?.completeResume != nil || (channel == .vscodeScreen && session.bridgeID.flatMap({ peers[$0] }) != nil) {
                if var state = capacityStates[id] {
                    state.observedAt = now
                    if state.phase == .cancelled || state.phase == .sending { capacityStates[id] = state; return }
                    state.stop = saved; state.submitOnly = true
                    if state.phase != .waiting { state.phase = .waiting; state.deadline = now.addingTimeInterval(capacityUnsentRetryDelay); state.scheduledID = nil }
                    capacityStates[id] = state
                } else {
                    var state = CapacityState(phase: .waiting, stop: saved, channel: channel, attempt: 1,
                        deadline: now.addingTimeInterval(capacityUnsentRetryDelay), observedAt: now)
                    state.submitOnly = true; capacityStates[id] = state
                }
                scheduleCapacityResume(id); return
            }
        }
        let stop = analysis.capacityStop
        if let stop {
            var recoveryProcesses: [Int32:ProcessRecord]?
            rememberExitContext(session,records:records,byPID:&recoveryProcesses)
            if session.interruption?.needsAttention != true || session.interruption?.kind != stop.kind {
                sessions[id]?.interruption = SessionInterruption(id:UUID().uuidString,kind:stop.kind,detail:stop.error,date:now)
                persistInterruption(id)
            }
            readRecoveryConversation(id)
        } else if analysis.activity.phase == .working, session.interruption?.needsAttention == true {
            sessions[id]?.interruption?.recoveredAt = now
            sessions[id]?.interruption?.resumeUncertain = false
            persistInterruption(id)
        }
        let channel = ScreenHost(kind:session.terminal).flatMap { screenConnections[$0]?.enabled == true ? $0.channel : nil } ?? session.channel
        guard session.automatic, channel.isScreen else { capacityStates.removeValue(forKey: id); return }
        if var state = capacityStates[id] {
            if let stop {
                state.observedAt = now
                switch state.phase {
                case .sending:
                    capacityStates[id] = state
                case .sent:
                    // Time alone cannot prove another failure. An unchanged error may
                    // remain after completion; only a changed transcript or observed work
                    // followed by this stop can authorize another continuation.
                    let elapsed = now.timeIntervalSince(state.sentAt ?? now)
                    let newFailedTurn = failedTurnAdvanced(id, after: state.turnIdentity, at: now)
                    if stop.continuationKey != state.stop.continuationKey || state.workingObserved || newFailedTurn {
                        let attempt = elapsed >= capacityProgressWindow ? 1 : state.attempt + 1
                        startCapacityRun(id, stop: stop, channel: channel, attempt: attempt, at: now)
                    } else {
                        capacityStates[id] = state
                    }
                case .waiting, .unavailable, .review, .cancelled:
                    let advanced = state.phase == .review && failedTurnAdvanced(id, after: state.turnIdentity, at: now)
                    if stop.continuationKey != state.stop.continuationKey || advanced {
                        // Someone continued by hand. A spacing-only redraw is still ours.
                        // A later failed root turn also resolves an uncertain earlier send.
                        if advanced { sessions[id]?.interruption?.resumeUncertain = false; persistInterruption(id) }
                        startCapacityRun(id, stop: stop, channel: channel, attempt: advanced ? state.attempt + 1 : 1, at: now)
                    } else {
                        state.stop = stop; capacityStates[id] = state
                        if state.phase == .waiting, state.scheduledID == nil { scheduleCapacityResume(id) }
                        else if state.phase == .unavailable,
                                ScreenHost(channel: channel).flatMap({ screenAdapters[$0] }) != nil ||
                                    (channel == .vscodeScreen && session.bridgeID.flatMap({ peers[$0] }) != nil) {
                            startCapacityRun(id, stop: stop, channel: channel, attempt: state.attempt, at: now)
                        }
                    }
                }
            } else {
                let phase = analysis.activity.phase
                switch state.phase {
                case .sending: break
                case .sent:
                    if phase == .working { capacityStates[id]?.workingObserved = true }
                    let elapsed = now.timeIntervalSince(state.sentAt ?? now)
                    if elapsed > 10, CodexResumeCheck.draftVisible(raw, text: state.stop.continuationText) {
                        capacityStates[id]?.phase = .review
                    } else if phase == .idle || (phase != .unknown && elapsed >= capacityProgressWindow) {
                        // Ended normally, or kept working: the run of failures is over.
                        sessions[id]?.interruption?.recoveredAt = now
                        sessions[id]?.interruption?.resumeUncertain = false
                        persistInterruption(id)
                        capacityStates.removeValue(forKey: id)
                    }
                case .review where CodexResumeCheck.draftVisible(raw, text: state.stop.continuationText):
                    break // Our unsent text still waits in the composer for the user.
                case .waiting, .unavailable, .review, .cancelled:
                    // The user typed or a turn is running. A partial repaint keeps the stop.
                    if phase != .unknown || CodexResumeCheck.composerChanged(raw, region: state.stop.region) {
                        capacityStates.removeValue(forKey: id)
                    }
                }
            }
        } else if let stop {
            startCapacityRun(id, stop: stop, channel: channel, attempt: 1, at: now)
        }
    }

    /// One phase per frame: a stopped turn shows as such, and asks for attention only once automation gave up.
    private func presentPhase(_ id: String, _ observed: ActivityObservation, at now: Date) {
        // Turning idle is the moment a held group message can be typed, for every agent and screen
        // source; waking the delivery loop here replaces retrying held messages on a timer.
        let before = sessions[id]?.phase
        defer {
            if groupMailboxTask != nil, before != .idle, sessions[id]?.phase == .idle {
                groupMailboxIdleSessions.insert(id); groupMailboxSignal.notify()
            }
        }
        var activity = observed
        // A custom Claude status line hides the idle composer from the screen reader. Claude still
        // records idle/busy for its own process, so an unreadable screen falls back to that record.
        // Waiting is never taken from the registry: approvals and answers need the parsed request.
        if activity.phase == .unknown, sessions[id]?.agent == .claude, let status = claudeRegistryStatus[id] {
            switch status {
            case "idle": activity = ActivityObservation(phase: .idle, detail: "Claude가 다음 지시를 기다리고 있습니다. (Claude 세션 기록 기준)")
            case "shell": activity = ActivityObservation(phase: .idle, detail: "Claude가 다음 지시를 기다리고 있습니다. 백그라운드 셸 작업은 계속 실행 중입니다. (Claude 세션 기록 기준)")
            case "busy": activity = ActivityObservation(phase: .working, detail: "Claude가 작업 중입니다. (Claude 세션 기록 기준)")
            default: break
            }
        }
        guard let state = capacityStates[id], state.phase != .sent else {
            sessions[id]?.setPhase(activity.phase, detail: activity.detail, at: now, monitoring: activity.monitoring)
            return
        }
        let detail = "\(state.stop.kind.title)로 \(sessions[id]?.agent.title ?? "CLI") 작업이 멈췄습니다."
        guard state.phase == .review else {
            sessions[id]?.setPhase(activity.phase, detail: detail, at: now, monitoring: activity.monitoring)
            return
        }
        sessions[id]?.setPhase(.input, detail: detail, at: now)
        sessions[id]?.pendingSummary = state.stop.kind.retryable
            ? "이어서 진행 요청의 전달 결과를 확인하지 못했습니다. 같은 입력은 다시 보내지 않습니다. 원본 입력창을 확인해주세요."
            : "인증 또는 설정 오류를 해결한 뒤 같은 세션에서 이어서 진행해주세요."
        sessions[id]?.pendingInTerminal = true
        sessions[id]?.pendingRequestID = "capacity:review:\(state.stop.identity)"
    }

    private func failedTurnIdentity(_ id: String, at now: Date) -> String? {
        guard let turn = codexTurns[id], now.timeIntervalSince(turn.observedAt) >= -5,
              now.timeIntervalSince(turn.observedAt) < 6, turn.state.status == "failed",
              let turnID = turn.state.turnID else { return nil }
        return turn.state.threadID + ":" + turnID
    }

    private func failedTurnAdvanced(_ id: String, after previous: String?, at now: Date) -> Bool {
        guard let previous, let next = failedTurnIdentity(id, at: now), next != previous,
              let thread = codexTurns[id]?.state.threadID else { return false }
        return previous.hasPrefix(thread + ":")
    }

    private func recoveryDelays(for kind: SessionInterruption.Kind) -> [TimeInterval] {
        switch kind {
        case .capacity: return capacityResumeDelays
        case .goalBlocked: return goalBlockedResumeDelays
        case .authentication, .configuration: return accountErrorResumeDelays
        case .transport, .api: return interruptionResumeDelays
        }
    }

    private func startCapacityRun(_ id: String, stop: CodexCapacityStop, channel: ApprovalChannel, attempt: Int, at now: Date) {
        if hasManualGoalHold(id) {return}
        let delays = recoveryDelays(for: stop.kind)
        var state = CapacityState(phase: .waiting, stop: stop, channel: channel, attempt: attempt,
            deadline: now, observedAt: now)
        state.turnIdentity = failedTurnIdentity(id, at: now)
        let previousIdentity = sessions[id]?.interruption?.resumeIdentity
        let advanced = failedTurnAdvanced(id, after: sessions[id]?.interruption?.resumeTurnIdentity, at: now)
        if advanced, sessions[id]?.interruption?.resumeUncertain == true {
            sessions[id]?.interruption?.resumeUncertain = false
            persistInterruption(id)
        }
        if delays.isEmpty || !stop.kind.retryable || (sessions[id]?.interruption?.resumeUncertain == true &&
            (previousIdentity == stop.continuationKey || previousIdentity == stop.identity ||
                (sessions[id]?.interruption?.resumeCommand == nil && previousIdentity == stop.legacyContinuationKey))) {
            state.phase = .review
            state.turnIdentity = sessions[id]?.interruption?.resumeTurnIdentity ?? state.turnIdentity
        } else if let confirmed = sessions[id]?.interruption?.resumeConfirmedAt,
                  previousIdentity == stop.continuationKey || previousIdentity == stop.identity,
                  !advanced {
            state.phase = .sent; state.sentAt = confirmed
            state.turnIdentity = sessions[id]?.interruption?.resumeTurnIdentity
        } else if ScreenHost(channel: channel).flatMap({ screenAdapters[$0] }) == nil &&
                    !(channel == .vscodeScreen && sessions[id]?.bridgeID.flatMap({peers[$0]}) != nil) {
            state.phase = .unavailable
        } else {
            state.deadline = now.addingTimeInterval(delays[min(attempt - 1,delays.count - 1)])
        }
        capacityStates[id] = state
        if state.phase == .waiting { scheduleCapacityResume(id) }
    }

    private func osPermissionSource(_ session:AgentSession)->String {"\(session.agent.rawValue):\(session.pid):\(session.started):\(session.tty)"}
    private func saveOSPermissionPolicy(_ session:AgentSession,_ policy:OSPermissionPolicy) throws {
        var policy=policy;policy.revision=UUID().uuidString
        let value=OSPermissionPolicyEnvelope(source:osPermissionSource(session),policy:policy)
        try store.set("osPermissionPolicy:"+session.id,String(decoding:JSONEncoder().encode(value),as:UTF8.self))
        sessions[session.id]?.osPermissionPolicy=policy
        osPermissionPolicySources[session.id]=osPermissionSource(session)
    }
    public func setOSPermissionPolicy(_ id:String,allowed:[OSPermissionKind]) throws {
        guard !allowed.contains(.authentication) else {throw RemoteHTTPError(400,"Mac 사용자 인증은 자동 승인 정책으로 허용할 수 없습니다.")}
        guard let session=sessions[id],session.agent != .shell,session.pid>0,session.phase != .ended else {throw RemoteHTTPError(404,"실행 중인 Codex·Claude 세션을 선택해주세요.")}
        var policy=osPermissionPolicySources[id]==osPermissionSource(session) ? session.osPermissionPolicy ?? .init():.init();policy.allowed=Array(Set(allowed)).sorted {$0.rawValue<$1.rawValue}
        let event=AuditEvent(sessionID:id,summary:"OS 권한 정책 변경",outcome:allowed.isEmpty ? "직접 확인":"허용: "+policy.allowed.map(\.title).joined(separator:", "),source:"세션 OS 권한 정책",context:AuditContext(session:session))
        guard log(event) else {throw RemoteHTTPError(503,"정책 변경 기록을 저장하지 못했습니다.")}
        try saveOSPermissionPolicy(session,policy)
        osPermissionTransitions=osPermissionTransitions.filter {$0.value.sessionID != id || allowed.contains($0.value.kind)}
        for (key,claim) in osPermissionClaims where claim.sessionID==id && osPermissionRequests[key].map({!allowed.contains($0.kind)})==true {osPermissionClaims.removeValue(forKey:key)}
        // Every already-queued terminal action must use a fresh policy observation.
        cancelCodexProgressCheck(id);codexProgressTrackers.removeValue(forKey:id)
        publish()
    }
    public func assignOSPermission(_ id:String,requestID:String,token:String,remember:Bool) throws {
        guard let session=sessions[id],session.agent != .shell,session.phase != .ended,
              let request=osPermissionRequests[requestID],request.isPending,request.phase == .waiting,
              request.immutableToken==token,let target=request.requester,let seen=osPermissionSeen[requestID],Date().timeIntervalSince(seen)<6 else {throw RemoteHTTPError(409,"현재 OS 요청과 앱 신원을 다시 확인해주세요.")}
        guard !request.isManagementApp else {throw RemoteHTTPError(409,"AutoApprove 자체의 권한은 CLI 세션 정책에 연결할 수 없습니다. Mac에서 직접 설정해주세요.")}
        guard request.sessionID==nil || request.sessionID==id else {throw RemoteHTTPError(409,"다른 세션에 연결된 요청입니다.")}
        if remember {
            guard !target.isSharedController else {throw RemoteHTTPError(409,"여러 세션이 공유하는 제어 앱은 현재 요청만 연결할 수 있습니다.")}
            guard !sessions.values.contains(where:{$0.id != id && $0.phase != .ended && $0.osPermissionPolicy?.targets.contains(where:{$0.matches(target)})==true}) else {throw RemoteHTTPError(409,"이 앱은 다른 실행 세션에 등록되어 있습니다. 그 세션에서 먼저 해제해주세요.")}
        }
        guard log(AuditEvent(sessionID:id,summary:"OS 권한 요청 연결 · "+target.name,outcome:remember ? "이 세션의 테스트 앱 등록":"현재 요청만 연결",source:"세션 OS 권한 정책",context:AuditContext(session:session),request:request.content)) else {throw RemoteHTTPError(503,"요청 연결 기록을 저장하지 못했습니다.")}
        if remember {
            var policy=osPermissionPolicySources[id]==osPermissionSource(session) ? session.osPermissionPolicy ?? .init():.init();policy.targets.removeAll {$0.id==target.id};policy.targets.append(target)
            guard policy.targets.count<=32 else {throw RemoteHTTPError(400,"세션당 등록 앱은 32개까지입니다.")}
            try saveOSPermissionPolicy(session,policy)
        }
        osPermissionClaims[requestID]=(id,token,osPermissionSource(session));osPermissionRequests[requestID]?.sessionID=id
        publishOSPermissions();publish()
    }
    public func removeOSPermissionTarget(_ id:String,targetID:String) throws {
        guard let session=sessions[id] else {throw RemoteHTTPError(404,"세션을 찾지 못했습니다.")}
        var policy=session.osPermissionPolicy ?? .init();policy.targets.removeAll {$0.id==targetID}
        guard log(AuditEvent(sessionID:id,summary:"OS 권한 등록 앱 해제",outcome:"후속 자동 승인 중지",source:"세션 OS 권한 정책",context:AuditContext(session:session))) else {throw RemoteHTTPError(503,"정책 변경 기록을 저장하지 못했습니다.")}
        try saveOSPermissionPolicy(session,policy)
        osPermissionTransitions=osPermissionTransitions.filter {!($0.value.sessionID==id && $0.value.target.id==targetID)}
        for (key,claim) in osPermissionClaims where claim.sessionID==id && osPermissionRequests[key]?.requester?.id==targetID {osPermissionClaims.removeValue(forKey:key)}
        publish()
    }
    public func acknowledgeOSPermission(_ id:String,requestID:String,token:String) throws {
        guard var request=osPermissionRequests[requestID],request.sessionID==id,request.immutableToken==token,let session=sessions[id] else {throw RemoteHTTPError(409,"이 세션에 연결된 원래 요청을 확인해주세요.")}
        guard log(AuditEvent(sessionID:id,summary:"OS 권한 결과 직접 확인",outcome:"사용자가 확인 완료로 표시",source:"세션 OS 권한 정책",context:AuditContext(session:session),request:request.content)) else {throw RemoteHTTPError(503,"확인 기록을 저장하지 못했습니다.")}
        request.phase = .resolved;request.detail="사용자가 Mac에서 처리 완료로 표시했습니다. OS 권한 부여 여부는 원래 앱에서 확인해주세요."
        try store.set("osPermissionReceipt:"+requestID,String(decoding:JSONEncoder().encode(request),as:UTF8.self))
        osPermissionReceipts.insert(requestID);osPermissionRequests[requestID]=request;publishOSPermissions();publish()
    }
    /// Explicit per-request response. Automatic policy and session AUTO are not changed.
    public func respondOSPermission(_ id:String,requestID:String,token:String,buttonID:String) throws {
        guard !remoteInputStopped,!snapshot.paused,osPermissionActing==nil,
              let original=sessions[id],original.agent != .shell,original.phase != .ended,
              let request=osPermissionRequests[requestID],request.sessionID==id,request.phase == .waiting,
              request.immutableToken==token,!request.isManagementApp,request.requester != nil,
              request.action != .manual,request.action != .enableSetting,
              let choice=request.buttons?.first(where:{$0.id==buttonID}),
              let seen=osPermissionSeen[requestID],Date().timeIntervalSince(seen)<6,
              !osPermissionReceipts.contains(requestID),!automaticInputBusy(id) else {throw RemoteHTTPError(409,"이 세션에 연결된 현재 OS 요청과 버튼을 다시 확인해주세요. 전체 일시정지 중에는 응답할 수 없습니다.",diagnostics:["delivery":"not_started"])}
        let source=osPermissionSource(original),epoch=osPermissionEpoch
        func authorized()->Bool {
            guard epoch==osPermissionEpoch,!remoteInputStopped,!snapshot.paused,
                  let current=sessions[id],current.phase != .ended,osPermissionSource(current)==source,
                  let currentRequest=osPermissionRequests[requestID],currentRequest.immutableToken==token,currentRequest.sessionID==id,currentRequest.buttons?.contains(choice)==true,
                  let records=try? singleProcessReader(original.pid) else {return false}
            return records.contains {$0.pid==original.pid && $0.started==original.started && "/dev/"+$0.tty==original.tty && $0.agent==original.agent}
        }
        guard authorized() else {throw RemoteHTTPError(409,"원래 세션 프로세스가 바뀌어 OS 버튼을 누르지 않았습니다.",diagnostics:["delivery":"not_started"])}
        osPermissionActing=requestID;defer {osPermissionActing=nil}
        var event=AuditEvent(sessionID:id,summary:"OS 요청 직접 응답 · "+choice.title,outcome:"버튼 전달 전 확인",source:"세션 OS 요청 응답",context:AuditContext(session:original),request:request.content)
        guard log(event) else {throw RemoteHTTPError(503,"OS 응답 기록을 저장하지 못했습니다.",diagnostics:["delivery":"not_started"])}
        var receipt=request;receipt.phase = .uncertain;receipt.detail="OS 버튼 전달 시작 기록이 있습니다. 결과 미확인 시 다시 누르지 않습니다."
        try store.set("osPermissionReceipt:"+requestID,String(decoding:JSONEncoder().encode(receipt),as:UTF8.self))
        osPermissionReceipts.insert(requestID);osPermissionRequests[requestID]?.phase = .approving
        let delivery=osPermissionServices.respond(request,choice,authorized)
        switch delivery {
        case .sent:
            receipt.phase=choice.kind == .openSettings ? .settings:.submitted
            receipt.detail="‘\(choice.title)’ 버튼을 원래 Mac 창에 한 번 전달했습니다. 원래 앱에서 결과를 확인해주세요."
            if choice.kind == .openSettings,let target=request.requester {osPermissionTransitions[requestID] = .init(target:target,kind:request.kind,sessionID:id,source:source,until:Date().addingTimeInterval(30))}
            event.outcome="선택한 OS 버튼 전달 · "+choice.title
        case .unavailable(let message):receipt.detail=message;event.outcome="OS 버튼 미전달 · 확인 필요"
        case .uncertain(let message):receipt.detail=message;event.outcome="OS 버튼 결과 미확인"
        }
        osPermissionRequests[requestID]=receipt
        try store.set("osPermissionReceipt:"+requestID,String(decoding:JSONEncoder().encode(receipt),as:UTF8.self));_ = log(event)
        publishOSPermissions();publish()
        switch delivery {
        case .sent:break
        case .unavailable(let message):throw RemoteHTTPError(409,message,diagnostics:["delivery":"not_started"])
        case .uncertain(let message):throw RemoteHTTPError(409,message,diagnostics:["delivery":"unknown"])
        }
    }
    private func hasOSPermissionWait(_ id:String)->Bool {
        osPermissionRequests.values.contains {!$0.isManagementApp && $0.isPending && ($0.sessionID==nil || $0.sessionID==id)}
    }
    private func publishOSPermissions() {
        var status=snapshot.osPermissions ?? .init()
        status.requests=osPermissionRequests.values.sorted {a,b in a.observedAt==b.observedAt ? a.id<b.id:a.observedAt>b.observedAt}
        if snapshot.osPermissions != status {snapshot.osPermissions=status}
        for id in sessions.keys {
            let waiting=hasOSPermissionWait(id)
            if waiting {cancelCodexProgressCheck(id);codexProgressTrackers.removeValue(forKey:id);if sessions[id]?.codexProgressRecovery?.phase != .review {sessions[id]?.codexProgressRecovery=nil}}
            if osPermissionBlocked.contains(id) && !waiting {
                automationNeedsFreshScreen.insert(id);invalidateRemoteRead(id)
                if let host=sessions[id].flatMap({ScreenHost(kind:$0.terminal)}) {screenPollSignals[host]?.notify()}
            }
            if waiting {osPermissionBlocked.insert(id)} else {osPermissionBlocked.remove(id)}
            sessions[id]?.osPermissionWaiting=osPermissionRequests.values.contains {!$0.isManagementApp && $0.isPending && $0.sessionID==id}
        }
    }
    public func refreshOSPermissions() async {
        guard !osPermissionScanning,!remoteInputStopped,sessions.values.contains(where:{$0.agent != .shell && $0.phase != .ended}) else {return}
        osPermissionScanning=true;defer {osPermissionScanning=false}
        osPermissionTransitions=osPermissionTransitions.filter {entry in guard let session=sessions[entry.value.sessionID] else {return false};return entry.value.until>Date() && session.phase != .ended && entry.value.source==osPermissionSource(session)}
        let epoch=osPermissionEpoch,service=osPermissionServices,targets=sessions.values.flatMap {$0.osPermissionPolicy?.targets ?? []}+osPermissionTransitions.values.map(\.target)
        do {
            let scanned=try await Task.detached(priority:.utility) {try service.scan(targets)}.value
            guard !Task.isCancelled,epoch==osPermissionEpoch,!remoteInputStopped else {return}
            let before=snapshot.osPermissions,now=Date(),seen=Set(scanned.requests.map(\.id))
            for fresh in scanned.requests {
                var request=fresh
                request.managementApp=request.isManagementApp ? true:nil
                osPermissionSeen[request.id]=now
                if let previous=osPermissionRequests[request.id],previous.immutableToken==request.immutableToken {
                    request.phase=previous.phase;request.detail=previous.detail;request.observedAt=previous.observedAt
                    if previous.phase == .resolved {request.phase = .uncertain;request.detail="OS 권한창이 아직 열려 있습니다. 이전 조작을 반복하지 않고 Mac에서 직접 확인을 기다립니다."}
                } else if let saved=store.value("osPermissionReceipt:"+request.id),let decoded=try? JSONDecoder().decode(OSPermissionRequest.self,from:Data(saved.utf8)) {
                    osPermissionReceipts.insert(request.id);request.phase = decoded.phase == .resolved ? .resolved:.uncertain
                    request.detail="이 요청에는 이전 조작 기록이 있습니다. 자동으로 다시 누르지 않습니다. 원래 Mac에서 확인해주세요."
                    request.sessionID=decoded.sessionID
                }
                if let claim=osPermissionClaims[request.id],claim.token==request.immutableToken,let session=sessions[claim.sessionID],session.phase != .ended,claim.source==osPermissionSource(session) {request.sessionID=claim.sessionID}
                else if request.action == .enableSetting,let target=request.requester {
                    let transitions=osPermissionTransitions.values.filter {$0.target==target && $0.kind==request.kind && $0.until>now}
                    if transitions.count==1 {request.sessionID=transitions[0].sessionID;osPermissionClaims[request.id]=(transitions[0].sessionID,request.immutableToken,transitions[0].source)}
                }
                else if let target=request.requester {
                    let owners=sessions.values.filter {$0.phase != .ended && osPermissionPolicySources[$0.id]==osPermissionSource($0) && $0.osPermissionPolicy?.targets.contains(where:{$0.matches(target)})==true}
                    if owners.count==1 {request.sessionID=owners[0].id}
                }
                if request.isManagementApp {
                    request.sessionID=nil;osPermissionClaims.removeValue(forKey:request.id)
                    request.detail="AutoApprove 자체의 권한은 Mac에서 직접 설정해주세요. 이 대기는 다른 CLI의 승인 감지와 진행 확인을 막지 않습니다."
                } else if request.phase == .waiting {
                    if request.action == .manual {request.detail="Mac 사용자 인증이나 보호된 OS 조작이 필요합니다. 이 창은 Mac에서 직접 처리해주세요."}
                    else if request.requester==nil {request.detail="OS 요청 앱의 서명과 실행 신원을 확인하지 못해 자동 승인하지 않습니다."}
                    else if let id=request.sessionID,let session=sessions[id] {
                        request.detail=snapshot.paused ? "전체 일시정지 중입니다.":!session.automatic ? "이 세션의 자동 승인을 켜면 정책을 적용합니다.":session.osPermissionPolicy?.allowed.contains(request.kind)==true ? "이 세션의 허용 정책을 확인하고 있습니다.":"이 세션에서 \(request.kind.title) 권한을 허용하지 않았습니다."
                    } else {request.detail="요청 앱과 내용을 확인한 뒤 처리할 세션에 연결해주세요."}
                }
                osPermissionRequests[request.id]=request
            }
            for id in Array(osPermissionRequests.keys) where scanned.available && !seen.contains(id) {
                guard var old=osPermissionRequests[id] else {continue}
                if old.phase == .settings,!scanned.requests.contains(where:{$0.requester?.id==old.requester?.id && $0.kind==old.kind && $0.action == .enableSetting}) {
                    if osPermissionTransitions.values.contains(where:{$0.sessionID==old.sessionID && $0.target.id==old.requester?.id && $0.until>now}) {continue}
                    old.phase = .uncertain;old.detail="OS 설정의 원래 앱 스위치를 확인하지 못했습니다. Mac에서 권한과 앱 동작을 확인해주세요.";osPermissionRequests[id]=old;continue
                }
                if old.phase == .uncertain,old.action == .openSettings {continue}
                if old.phase != .resolved {
                    old.phase = .resolved;old.detail="원래 OS 권한창이 닫혔습니다. 원래 앱에서 접근 결과를 확인해주세요.";osPermissionRequests[id]=old
                }
                if now.timeIntervalSince(old.observedAt)>300 {osPermissionRequests.removeValue(forKey:id);osPermissionClaims.removeValue(forKey:id)}
            }
            var status=scanned;status.requests=[]
            if snapshot.osPermissions?.available != status.available || snapshot.osPermissions?.detail != status.detail {snapshot.osPermissions=status}
            publishOSPermissions()
            if before != snapshot.osPermissions {publish()}
            guard osPermissionActing==nil,!snapshot.paused,!scanned.requests.contains(where:{!$0.isManagementApp && $0.action == .manual && $0.isPending}) else {return}
            for request in osPermissionRequests.values.sorted(by:{$0.observedAt<$1.observedAt}) where request.phase == .waiting && seen.contains(request.id) {
                guard !request.isManagementApp,request.action != .manual,let id=request.sessionID,let original=sessions[id],original.automatic,original.phase != .ended,
                      osPermissionPolicySources[id]==osPermissionSource(original),original.osPermissionPolicy?.allowed.contains(request.kind)==true,request.requester != nil,
                      !userInputHasPriority(id),!automaticInputBusy(id),!osPermissionReceipts.contains(request.id) else {continue}
                let reader=singleProcessReader,pid=original.pid,automationEpoch=automationRuntime.epoch(id)
                let records=try await Task.detached(priority:.utility) {try reader(pid)}.value
                guard epoch==osPermissionEpoch,automationRuntime.epoch(id)==automationEpoch,!remoteInputStopped,!snapshot.paused,
                      osPermissionActing==nil,osPermissionRequests[request.id]?.phase == .waiting,!osPermissionReceipts.contains(request.id),
                      records.contains(where:{$0.pid==pid && $0.started==original.started && "/dev/"+$0.tty==original.tty && $0.agent==original.agent}) else {continue}
                osPermissionActing=request.id;defer {osPermissionActing=nil}
                var event=AuditEvent(sessionID:id,summary:"OS 권한 정책 승인 · "+request.kind.title,outcome:"허용 입력 전 확인",source:"세션 OS 권한 정책",context:AuditContext(session:original),request:request.content)
                guard log(event) else {continue}
                var receipt=request;receipt.phase = .uncertain;receipt.detail="조작 시작 기록이 있습니다. 결과 미확인 시 자동 반복하지 않습니다."
                try store.set("osPermissionReceipt:"+request.id,String(decoding:JSONEncoder().encode(receipt),as:UTF8.self));osPermissionReceipts.insert(request.id)
                osPermissionRequests[request.id]?.phase = .approving
                let delivery=service.approve(request) { [self] in
                    guard epoch==osPermissionEpoch,automationRuntime.epoch(id)==automationEpoch,!remoteInputStopped,!snapshot.paused,!userInputHasPriority(id),
                          let current=sessions[id],osPermissionSource(current)==osPermissionSource(original),current.automatic,current.phase != .ended,
                          osPermissionPolicySources[id]==osPermissionSource(current),current.osPermissionPolicy?.allowed.contains(request.kind)==true,osPermissionRequests[request.id]?.immutableToken==request.immutableToken else {return false}
                    guard let live=try? singleProcessReader(original.pid),live.contains(where:{$0.pid==original.pid && $0.started==original.started && "/dev/"+$0.tty==original.tty && $0.agent==original.agent}) else {return false}
                    return current.osPermissionPolicy?.permits(request)==true || osPermissionClaims[request.id].map {$0.sessionID==id && $0.token==request.immutableToken && $0.source==osPermissionSource(current)}==true
                }
                switch delivery {
                case .sent:
                    receipt.phase=request.action == .openSettings ? .settings:.submitted
                    if request.action == .openSettings,let target=request.requester {osPermissionTransitions[request.id] = .init(target:target,kind:request.kind,sessionID:id,source:osPermissionSource(original),until:Date().addingTimeInterval(30))}
                    if request.action == .enableSetting {osPermissionTransitions=osPermissionTransitions.filter {!($0.value.target==request.requester && $0.value.kind==request.kind && $0.value.sessionID==id)}}
                    receipt.detail=request.action == .openSettings ? "OS 설정을 열었습니다. 같은 앱의 허용 스위치를 확인합니다. 인증이 필요하면 Mac에서 직접 처리해주세요.":"OS 권한 허용 입력을 한 번 전달했습니다. 권한창과 원래 앱의 결과를 확인합니다."
                    event.outcome=request.action == .openSettings ? "OS 설정 열기 전달":"OS 허용 입력 전달"
                case .unavailable(let message):receipt.phase = .uncertain;receipt.detail=message;event.outcome="OS 입력 미전달 · 확인 필요"
                case .uncertain(let message):receipt.phase = .uncertain;receipt.detail=message;event.outcome="OS 입력 결과 미확인"
                }
                osPermissionRequests[request.id]=receipt
                try store.set("osPermissionReceipt:"+request.id,String(decoding:JSONEncoder().encode(receipt),as:UTF8.self));_ = log(event)
                publishOSPermissions();publish();break
            }
        } catch {
            var status=snapshot.osPermissions ?? .init();status.available=false;status.detail="OS 권한 연결 확인 실패: "+String(error.localizedDescription.prefix(500))
            if snapshot.osPermissions != status {snapshot.osPermissions=status;publish()}
        }
    }

    public func setCodexProgressRecoveryEnabled(_ enabled:Bool) throws {
        try store.set("codexProgressRecoveryEnabled",enabled ? "true":"false")
        snapshot.codexProgressRecoveryEnabled=enabled
        for id in Array(codexProgressJobs.keys) {cancelCodexProgressCheck(id)}
        codexProgressTrackers.removeAll()
        for id in sessions.keys {sessions[id]?.codexProgressRecovery=nil}
        publish()
    }
    public func setCodexAccountTransitionEnabled(_ enabled: Bool) throws {
        guard !codexAccountTransitionBusy else { throw AppError.message("진행 중인 계정 확인·전환 결과를 기다려주세요.") }
        if !enabled {
            for home in codexAccountTransitionStates.keys where codexAccountTransitionStates[home]?.held == true {
                try cancelCodexAccountTransition(home: home)
            }
        }
        try persistCodexAccountTransitionEnabled(enabled)
    }
    private func persistCodexAccountTransitionEnabled(_ enabled:Bool) throws {
        try store.set("codexAccountTransitionEnabled", enabled ? "true" : "false")
        codexAccountTransitionEnabled = enabled
        if enabled, pollTask != nil { startCodexAccountTransitionPolling() }
    }
    public func codexLoginTargets() async throws -> [CodexAccountTransitionTarget] {
        let reader = processReader
        let records = try await Task.detached(priority: .utility) { try reader() }.value
        return try await codexAccountTargetReader(records)
    }
    public var codexLoginGroupStore:CodexLoginGroupStore {
        .init(directory:paths.directory.appendingPathComponent("codex-login-groups",isDirectory:true))
    }
    var codexIndependentLoginStore:CodexIndependentLoginStore {
        .init(directory:paths.directory.appendingPathComponent("codex-independent-sessions",isDirectory:true))
    }
    private func validateCodexLoginHome(_ home:String)throws {
        try codexLoginGroupStore.validate(home:home)
        try codexIndependentLoginStore.validate(home:home)
    }
    public func codexIndependentLogins() async throws->[CodexIndependentLogin] {
        let store=codexIndependentLoginStore
        return try await Task.detached(priority:.utility){try store.list()}.value
    }
    public func createCodexIndependentLogin(name:String,dedicatedServer:Bool=false) async throws->CodexIndependentLogin {
        guard !remoteInputStopped else{throw AppError.message("앱이 종료 중입니다.")}
        let store=codexIndependentLoginStore
        let home=try await Task.detached(priority:.utility){try store.create(name:name,dedicatedServer:dedicatedServer)}.value
        objectWillChange.send()
        return home
    }
    public func copyCodexLoginToIndependentHome(sessionID:String,independentID:UUID) async throws {
        guard !remoteInputStopped,!codexAccountTransitionBusy,!codexAccountTransitionHeld,!agentAccounts.busy else {
            throw AppError.message("진행 중인 로그인·전환을 마친 뒤 독립 로그인을 준비해주세요.")
        }
        let epoch=codexAccountTransitionEpoch
        codexAccountTransitionBusy=true
        defer{if epoch==codexAccountTransitionEpoch{codexAccountTransitionBusy=false}}
        let source=try await codexSessionAccount(sessionID:sessionID)
        let saved=try await inspectCodexAccount(home:source.target.home)
        guard saved.comparison == .same,source.identity.authenticated,
              let destination=try await codexIndependentLogins().first(where:{$0.id==independentID}) else {
            throw AppError.message("현재 그룹의 저장된 로그인과 독립 홈을 확인해주세요.")
        }
        let sourceHome=source.target.home,targetHome=destination.home
        try await Task.detached(priority:.utility) {
            let credential=try CodexCredentialFile.capture(home:sourceHome)
            try credential.copyConfigurationForIndependentLogin(to:targetHome)
            try credential.copyForIndependentLogin(to:targetHome)
        }.value
        if destination.usesDedicatedServer {
            try await Task.detached(priority:.utility) {
                guard let cli=try CodexOfficialExecutable.resolve(home:targetHome,userHome:NSHomeDirectory(),executable:source.target.executable),
                      try cli.run(["features","enable","daemon_auto_start"]).status==0 else{throw AppError.message("전용 로그인 서버의 시작 설정을 적용하지 못했습니다.")}
            }.value
        }else{try await disableIndependentDaemonAutoStart(home:targetHome,executable:source.target.executable)}
        let fresh=try await codexSessionAccount(sessionID:sessionID)
        guard epoch==codexAccountTransitionEpoch,!remoteInputStopped,
              fresh.target==source.target,fresh.identity==source.identity,fresh.serverPID==source.serverPID else {
            throw AppError.message("로그인 준비 중 원래 그룹의 계정이 바뀌었습니다. 독립 홈의 계정을 다시 확인해주세요.")
        }
    }
    private func disableIndependentDaemonAutoStart(home:String,executable:String) async throws {
        try await Task.detached(priority:.utility) {
            guard let cli=try CodexOfficialExecutable.resolve(home:home,userHome:NSHomeDirectory(),executable:executable),
                  try cli.run(["features","disable","daemon_auto_start"]).status==0 else {
                throw AppError.message("독립 홈의 자동 서버 연결을 끄지 못했습니다. 실행하지 않고 설정을 유지합니다.")
            }
        }.value
    }
    /// Reads only the selected execution; no server preparation or terminal input.
    public func codexStandaloneSession(sessionID:String) async throws->CodexStandaloneSession {
        guard let original=sessions[sessionID],original.agent == .codex,original.phase != .ended else {
            throw AppError.message("실행 중인 Codex 세션을 선택해주세요.")
        }
        let reader=processReader
        let records=try await Task.detached(priority:.utility){try reader()}.value
        let targets=try await codexAccountTargetReader(records)
        guard !targets.contains(where:{$0.witnesses.contains(where:{$0.pid==original.pid && $0.started==original.started})}) else {
            throw AppError.message("이 세션은 이미 연결 서버를 사용하고 있습니다. 연결 계정을 새로 확인해주세요.")
        }
        let selectedHome:String
        if let selected=try? await CodexReplyTransport.selectedQueueTarget(original) {selectedHome=selected.home}
        else {
            guard let process=records.first(where:{$0.key==original.id}),
                  let environment=ProcessEnvironment.read(process,names:["CODEX_HOME","HOME"]),
                  let home=environment["CODEX_HOME"] ?? environment["HOME"].map({$0+"/.codex"}) else {
                throw AppError.message("독립 실행의 로그인 홈을 확인하지 못했습니다.")
            }
            selectedHome=home
        }
        let home=try CodexAccountTransitionTarget.canonicalHome(selectedHome)
        try codexLoginGroupStore.validate(home:home)
        try codexIndependentLoginStore.validate(home:home)
        let executable=try await Task.detached(priority:.utility) {
            guard let process=records.first(where:{$0.key==original.id && "/dev/"+$0.tty==original.tty}),
                  let path=CodexServerLocation.executable(process),
                  CodexServerLocation.connectedHome(pid:process.pid,hints:[home]+targets.map(\.home))==nil else {
                throw AppError.message("독립 실행의 원래 프로세스·로그인 홈을 확인하지 못했습니다.")
            }
            return path
        }.value
        guard !Task.isCancelled,!remoteInputStopped,let current=sessions[sessionID],
              current.pid==original.pid,current.started==original.started,current.tty==original.tty,current.phase != .ended else {
            throw AppError.message("독립 세션을 확인하는 중 실행이 바뀌었습니다.")
        }
        return .init(session:original,home:home,executable:executable)
    }
    /// Enroll just this standalone TUI in its own home's server first. The
    /// existing migration coordinator then moves it to the selected group.
    public func prepareStandaloneCodexSessionMove(sessionID:String,destinationHome:String) async throws->CodexSessionMovePlan {
        if CodexFeatureSupport.canMoveOpenSessions {return try await prepareStandaloneCodexCohortMove(sessionID:sessionID,destinationHome:destinationHome)}
        try CodexFeatureSupport.requireSessionMove()
        let source=try await codexStandaloneSession(sessionID:sessionID)
        guard source.home != (try CodexAccountTransitionTarget.canonicalHome(destinationHome)) else {
            throw AppError.message("다른 로그인 그룹을 선택해주세요.")
        }
        _=try await codexNativeDestinationServer(home:destinationHome)
        let before=try await codexManagedServerStatus(home:source.home)
        let server=before.canPrepare ? try await prepareCodexManagedServer(home:source.home):before
        guard server.phase == .running else{throw AppError.message(server.detail)}
        let deadline=Date().addingTimeInterval(125)
        while Date()<deadline {
            try Task.checkCancellation()
            await attachStandaloneCodexSessions(home:source.home,sessionIDs:[sessionID])
            guard let state=codexSessionAttachments[sessionID] else {
                throw AppError.message(codexAttachmentWaitReasons[sessionID] ?? "작업·Goal·초안이 끝난 뒤 다시 연결해주세요.")
            }
            if state.phase == .review {throw AppError.message(state.detail)}
            if state.phase == .connected {
                let reader=processReader
                let records=try await Task.detached(priority:.utility){try reader()}.value
                let shell=state.context.shell
                let candidates=records.filter{$0.agent == .codex && $0.tty==shell.tty
                    && ProcessDiscovery.ancestors(of:$0.parent,byPID:ProcessDiscovery.index(records)).contains(where:{$0.key==shell.key})}
                guard candidates.count==1,let next=candidates.first else {
                    throw AppError.message("서버 연결 뒤 원래 터미널의 세션을 다시 확인해주세요.")
                }
                await refresh()
                // Resuming the same conversation shows a goal-resume picker.
                // Dismiss that picker without activating the preserved Goal.
                if let paused=state.pausedGoal,let thread=state.context.conversationID,
                   let current=sessions[next.key],let host=ScreenHost(kind:current.terminal),
                   let adapter=screenAdapters[host] {
                    let target=ScreenTarget(tty:current.tty,handle:current.screenHandle,jobPIDs:[next.pid],sourcePID:next.pid,sourceStarted:next.started)
                    var snapshot=try await Task.detached(priority:.utility){try adapter.readForValidation([target])}.value
                    let pickerDeadline=Date().addingTimeInterval(5)
                    while Date()<pickerDeadline,!snapshot.screens.contains(where:{$0.contents.contains("Resume paused goal?")}) {
                        try await Task.sleep(for:.milliseconds(250))
                        snapshot=try await Task.detached(priority:.utility){try adapter.readForValidation([target])}.value
                    }
                    if snapshot.failures.isEmpty,snapshot.screens.count==1,let raw=snapshot.screens.first?.contents,
                       raw.contains("Resume paused goal?"),raw.contains("Mark it active and continue when idle"),
                       raw.contains("Keep it paused; use /goal resume later"),raw.contains("esc back") {
                        guard try await CodexStandaloneObservation.displays(home:source.home,pid:next.pid,threadID:thread),
                              try CodexSessionAttachment.goalIfPresent(home:source.home,threadID:thread)==paused,
                              !remoteInputStopped else {throw AppError.message("원래 대화·Goal 상태가 바뀌었습니다.")}
                        let result=try await Task.detached(priority:.utility){try adapter.input(target,raw,.codex,.init(kind:.escape))}.value
                        guard result == .sent else{throw AppError.message("Goal 재개 창에서 ‘Leave paused’를 선택한 뒤 다시 연결해주세요.")}
                        let readyDeadline=Date().addingTimeInterval(5)
                        var ready=false
                        while Date()<readyDeadline {
                            try await Task.sleep(for:.milliseconds(250))
                            let screen=try await Task.detached(priority:.utility){try adapter.readForValidation([target])}.value
                            if screen.failures.isEmpty,screen.screens.count==1,let contents=screen.screens.first?.contents,
                               CodexGoalScreen.ready(contents) {ready=true;break}
                        }
                        guard ready,try CodexSessionAttachment.goalIfPresent(home:source.home,threadID:thread)==paused else {
                            throw AppError.message("일시정지한 Goal과 빈 입력창을 확인한 뒤 다시 연결해주세요.")
                        }
                        await refresh()
                    }
                }
                return try await prepareCodexSessionMove(sessionID:next.key,destinationHome:destinationHome)
            }
            try await Task.sleep(for:.milliseconds(250))
        }
        throw AppError.message("독립 세션 연결 확인 시간이 지났습니다. 종료·실행 명령을 반복하지 않습니다.")
    }
    public func codexLoginGroups() async throws->[CodexLoginGroup] {
        let store=codexLoginGroupStore
        return try await Task.detached(priority:.utility){try store.list()}.value
    }
    private func sessionMigrationCoordinator()throws->CodexSessionMigrationCoordinator {
        if let existing=codexMigrationCoordinator{return existing}
        let coordinator=CodexSessionMigrationCoordinator(journal:try CodexMigrationJournal(store:store),
            services:.init(observe:{[weak self] request in
                guard let self else{throw CancellationError()}
                return try await self.codexMigrationObservation(request)
            }))
        codexMigrationCoordinator=coordinator
        return coordinator
    }
    private func refreshCodexMigrationHolds() {
        do {
            let states=try sessionMigrationCoordinator().activeStates()
            codexMigrationHeldClients=Set(states.flatMap{$0.request.clients.map(\.identity)})
            codexMigrationRecoveryError=nil
        }catch {codexMigrationRecoveryError=error.localizedDescription}
    }
    private func saveCodexMigrationReconnectContext(_ context:SessionExitRecovery?,id:String)throws {
        var values=codexMigrationReconnectContexts
        values[id]=context
        try store.set("codexMigrationReconnectContexts.v1",String(decoding:JSONEncoder().encode(values),as:UTF8.self))
        codexMigrationReconnectContexts=values
    }
    func prepareCodexSessionMigration(sessionID:String,destinationHome:String) async throws->CodexSessionMigrationState {
        try CodexFeatureSupport.requireSessionMove()
        guard !remoteInputStopped,!codexAccountTransitionBusy,!codexAccountTransitionHeld,!agentAccounts.busy else {
            throw AppError.message("진행 중인 로그인·계정 전환을 마친 뒤 이동해주세요.")
        }
        let epoch=codexAccountTransitionEpoch
        codexAccountTransitionBusy=true
        defer{refreshCodexMigrationHolds();if epoch==codexAccountTransitionEpoch{codexAccountTransitionBusy=false}}
        let request=try await codexMigrationRequest(sessionID:sessionID,destinationHome:destinationHome)
        let context=try await codexMigrationReconnectContext(sessionID:sessionID,request:request)
        guard epoch==codexAccountTransitionEpoch,!remoteInputStopped else{throw CancellationError()}
        try saveCodexMigrationReconnectContext(context,id:request.id)
        do {return try await sessionMigrationCoordinator().prepare(request)}
        catch {
            let original=error
            do {
                let state=try sessionMigrationCoordinator().state(id:request.id)
                if state==nil || state?.stage == .cancelled {try saveCodexMigrationReconnectContext(nil,id:request.id)}
            }catch { /* Retain the context when reservation outcome is unknown. */ }
            throw original
        }
    }
    func cancelCodexSessionMigration(id:String)throws {
        defer{refreshCodexMigrationHolds()}
        try sessionMigrationCoordinator().cancel(id:id)
        try saveCodexMigrationReconnectContext(nil,id:id)
    }
    public func prepareCodexSessionMove(sessionID:String,destinationHome:String) async throws->CodexSessionMovePlan {
        if CodexFeatureSupport.canMoveOpenSessions {
            return try await prepareCodexCohortMove(sessionID:sessionID,destinationHome:destinationHome)
        }
        return .init(try await prepareCodexSessionMigration(sessionID:sessionID,destinationHome:destinationHome))
    }
    private func cohortRestartDriver()->CodexCohortRestart {
        if let coordinator=cohortRestartCoordinator{return coordinator}
        let coordinator=CodexCohortRestart(store:store);cohortRestartCoordinator=coordinator;return coordinator
    }
    /// Observe current terminal Session IDs and the actual shared-server cohort.
    /// A private TUI connection census is not part of this preparation.
    public func prepareCodexCohortMove(sessionID:String,destinationHome:String) async throws ->CodexSessionMovePlan {
        guard !remoteInputStopped,!codexAccountTransitionBusy,!codexAccountTransitionHeld,!agentAccounts.busy else {
            throw AppError.message("진행 중인 계정 변경을 먼저 마쳐주세요.")
        }
        try validateCodexLoginHome(destinationHome)
        let account=try await codexSessionAccount(sessionID:sessionID)
        let destination=try CodexAccountTransitionTarget.canonicalHome(destinationHome)
        let source=account.target.home
        let witnesses=account.target.witnesses
        let related=sessions.values.filter {session in
            session.agent == .codex && session.phase != .ended && witnesses.contains(where:{$0.pid==session.pid && $0.started==session.started && $0.tty==session.tty})
        }.sorted{$0.id<$1.id}
        guard related.count==witnesses.count,related.contains(where:{$0.id==sessionID}) else{throw AppError.message("서버의 세션 목록이 바뀌었습니다. 목록을 갱신한 뒤 다시 준비해주세요.")}
        let peer=try await Task.detached(priority:.utility) {
            _=try CodexOfficialExecutable.verifyServer(CodexQueueConnection(home:destination))
            return try CodexOfficialExecutable.verifyServer(CodexQueueConnection(home:source))
        }.value
        return try await captureCodexCohortMove(sessionID:sessionID,destination:destination,source:source,related:related,peer:peer,restartServer:true)
    }
    /// Enroll one independent writer after persisting its /status identity.
    /// The existing managed server and its unrelated clients remain running.
    public func prepareStandaloneCodexCohortMove(sessionID:String,destinationHome:String,automaticEnrollment:Bool=false) async throws->CodexSessionMovePlan {
        guard !remoteInputStopped,!codexAccountTransitionBusy,!codexAccountTransitionHeld,!agentAccounts.busy else{throw AppError.message("진행 중인 계정 변경을 먼저 마쳐주세요.")}
        try validateCodexLoginHome(destinationHome)
        let standalone=try await codexStandaloneSession(sessionID:sessionID)
        let source=standalone.home,destination=try CodexAccountTransitionTarget.canonicalHome(destinationHome)
        let preserveStandalonePolicy=try codexIndependentLoginStore.requiresStandalone(home:source)
        let before=try await codexManagedServerStatus(home:source)
        let status:CodexManagedServerStatus
        do {status=before.canPrepare ? try await prepareCodexManagedServer(home:source):before}
        catch {
            if preserveStandalonePolicy && before.canPrepare {try await disableIndependentDaemonAutoStart(home:source,executable:standalone.executable)}
            throw error
        }
        if preserveStandalonePolicy && before.canPrepare {try await disableIndependentDaemonAutoStart(home:source,executable:standalone.executable)}
        guard status.phase == .running else{throw AppError.message("독립 실행의 원래 로그인 홈에 연결 서버를 준비하지 못했습니다. "+status.detail)}
        let peer=try await Task.detached(priority:.utility) {
            if source != destination {_=try CodexOfficialExecutable.verifyServer(CodexQueueConnection(home:destination))}
            return try CodexOfficialExecutable.verifyServer(CodexQueueConnection(home:source))
        }.value
        guard let original=sessions[sessionID],original.pid==standalone.pid,original.started==standalone.started,original.phase != .ended else{throw AppError.message("서버 준비 중 원래 독립 세션이 바뀌었습니다.")}
        return try await captureCodexCohortMove(sessionID:sessionID,destination:destination,source:source,related:[original],peer:peer,restartServer:false,automaticEnrollment:automaticEnrollment)
    }
    private func captureCodexCohortMove(sessionID:String,destination:String,source:String,related:[AgentSession],peer:CodexNativePeerIdentity,restartServer:Bool,automaticEnrollment:Bool=false) async throws->CodexSessionMovePlan {
        let reader=processReader
        var candidates:[TerminalProfileCandidate]=[],originals:[UUID:SessionExitRecovery]=[:]
        for session in related {
            try Task.checkCancellation()
            guard let host=ScreenHost(kind:session.terminal),screenConnections[host]?.enabled==true,screenAdapters[host]?.restart != nil else {
                throw AppError.message("관련 터미널의 화면 연결과 다시 실행 기능을 먼저 켜주세요.")
            }
            let conversation=try await statusConversationID(session)
            let rows=try await Task.detached(priority:.utility){try reader()}.value
            guard let process=rows.first(where:{$0.key==session.id && $0.agent == .codex && "/dev/"+$0.tty==session.tty}),
                  let shell=ProcessDiscovery.ancestors(of:process.parent,byPID:ProcessDiscovery.index(rows)).first(where:{$0.tty==process.tty && SessionExitRecovery.isShell($0)}) else {
                throw AppError.message("종료 후 돌아올 원래 터미널의 셸을 확인하지 못했습니다.")
            }
            let launch=try await Task.detached(priority:.utility){try CodexSessionLaunch.capture(process)}.value
            _=try await Task.detached(priority:.utility){try launch.officialContext()}.value
            guard try CodexAccountTransitionTarget.canonicalHome(launch.providerHome)==source else{throw AppError.message("조회 중 로그인 홈이 바뀌었습니다.")}
            var recovery=SessionExitRecovery(session:session,process:process,shell:shell,conversationID:conversation)
            recovery.codexLaunch=launch
            let entry=TerminalProfileEntry(title:session.project,agent:"codex",cwd:session.cwd,conversationID:conversation,
                providerHome:source,host:session.terminal == .iterm ? .iterm:.terminal)
            candidates.append(.init(id:session.id,entry:entry,tty:session.tty));originals[entry.id]=recovery
        }
        let rows=try await Task.detached(priority:.utility){try reader()}.value
        let plan=try CodexCohortRestartPlan.capture(sourceHome:source,destinationHome:destination,candidates:candidates,records:rows,
            movingSessionIDs:[sessionID],groups:SessionGroupStore(directory:paths.directory).load())
        guard let selected=candidates.first(where:{$0.id==sessionID}),let launch=originals[selected.entry.id]?.codexLaunch else{throw AppError.message("선택한 터미널의 실행 정보를 찾지 못했습니다.")}
        let roots=candidates.map{$0.entry.conversationID},movingRoot=selected.entry.conversationID
        let captured=try await Task.detached(priority:.utility) {
            let connection=try CodexQueueConnection(home:source)
            guard try CodexOfficialExecutable.verifyServer(connection)==peer else{throw AppError.message("준비 중 원래 서버가 바뀌었습니다.")}
            // Reject an incompatible original CLI/server or database before
            // stopping any terminal. The handoff supports the pinned original
            // 0.169 schema, including absent stores initialized by that server.
            for home in Set([source,destination]) {
                _=try CodexOfficialGoalStateAccess(home:home,userHome:launch.userHome,executable:launch.executable)
                try CodexGoalTransferStore.validateHomeIfPresent(home)
                try CodexThreadHistoryTransfer.validateHomeIfPresent(home)
            }
            let scope=try CodexMigrationThread.captureScope(connection:connection,home:source,rootIDs:roots)
            let moving=try CodexMigrationThread.captureScope(connection:connection,home:source,rootIDs:[movingRoot])
            var goals:[String:CodexGoal]=[:]
            for thread in scope {
                goals[thread.id]=try CodexSessionAttachment.goalIfPresent(home:source,threadID:thread.id)
            }
            return(scope,Set(moving.map(\.id)),goals)
        }.value
        guard !remoteInputStopped else{throw CancellationError()}
        if restartServer {
            let fresh=try await codexSessionAccount(sessionID:sessionID)
            guard fresh.target.home==source,Set(fresh.target.witnesses.map{"\($0.pid):\($0.started):\($0.tty)"})==Set(plan.members.map{"\($0.pid):\($0.started):\($0.tty)"}) else{throw AppError.message("이동 준비 중 관련 서버 세션이 바뀌었습니다. 종료하지 않고 다시 확인합니다.")}
        }
        let context=CodexCohortRestartContext(planID:plan.id,selectedSessionID:sessionID,launch:launch,originalServer:peer,
            originals:originals,scope:captured.0,movingThreads:captured.1,originalGoals:captured.2,
            transfers:Dictionary(uniqueKeysWithValues:captured.1.map{($0,UUID())}),restartServer:restartServer,
            processTree:try Dictionary(uniqueKeysWithValues:plan.members.map{($0.entryID,try CodexCohortProcessFence.capture(rootID:$0.runtimeID,records:rows))}),
            automaticEnrollment:automaticEnrollment ? true:nil)
        _=try cohortRestartDriver().prepare(plan,context:context)
        return .init(cohort:plan,conversationCount:context.movingThreads.count)
    }
    public func cancelCodexSessionMove(id:String)throws {
        if let uuid=UUID(uuidString:id),try cohortRestartDriver().state(uuid) != nil {try cohortRestartDriver().cancel(uuid);return}
        try cancelCodexSessionMigration(id:id)
    }
    public func codexSessionMoveRecoveries()throws->[CodexSessionMoveRecovery] {
        let cohorts=try cohortRestartDriver().active().map {value in
            let context=try cohortContext(value.plan.id)
            return CodexSessionMoveRecovery(id:value.plan.id.uuidString.lowercased(),destinationHome:value.plan.destinationHome,
                conversationCount:context.movingThreads.count,detail:value.phase == .captured ? "이동 준비됨 · 관련 세션 종료 전":"세션 재시작·복원 진행 확인 필요 · 저장된 단계에서 계속합니다.",
                canCancel:value.phase == .captured,canReconnect:value.phase != .captured)
        }
        let coordinator=try sessionMigrationCoordinator()
        let ids=Set(try coordinator.activeStates().map{$0.request.id}).union(codexMigrationReconnectContexts.keys)
        return cohorts + (try ids.sorted().compactMap { id in
            guard let state=try coordinator.state(id:id) else {
                throw AppError.message("재연결 정보에 대응하는 이동 기록을 찾지 못했습니다: "+id)
            }
            if state.stage == .cancelled{return nil}
            let canCancel=state.execution==nil
            let canReconnect=CodexFeatureSupport.canUsePrivateSessionAttachment && state.stage == .completed && codexMigrationReconnectContexts[id] != nil
            let detail:String
            if !CodexFeatureSupport.canUsePrivateSessionAttachment {detail=canCancel
                ? "이전 방식으로 준비한 이동입니다. 취소한 뒤 현재 대화로 다시 준비해주세요."
                : "이전 방식의 실행 결과 확인이 필요합니다. 저장된 기록만으로 종료·이전 명령을 반복하지 않습니다."}
            else if canReconnect {detail="대화 이전 완료 · 원래 터미널의 목적지 연결 확인이 남아 있습니다."}
            else if canCancel {detail="이동 범위 준비됨 · 아직 대화 이전을 실행하지 않았습니다."}
            else {detail="이전 실행 결과 확인 필요 · 종료·소유권 이전 명령을 반복하지 않습니다."}
            return .init(id:id,destinationHome:state.request.destination.home,conversationCount:state.request.threads.count,
                detail:detail,canCancel:canCancel,canReconnect:canReconnect)
        })
    }
    public func codexSessionMoveProgress(id:String)throws->CodexSessionMoveProgress? {
        guard let uuid=UUID(uuidString:id),let state=try cohortRestartDriver().state(uuid) else{return nil}
        let detail:String
        switch state.phase {
        case .captured:detail="이동 범위를 저장했습니다. 아직 세션을 종료하지 않았습니다."
        case .stopping:detail="원래 터미널 \(state.plan.members.count)개의 종료를 확인하고 있습니다."
        case .restarting:detail="공식 Codex 서버와 저장된 작업 상태를 확인하고 있습니다."
        case .transferring:detail="선택한 대화와 Goal 이력을 대상 로그인 홈으로 옮기고 있습니다."
        case .restoring:detail="원래 터미널 복원 \(state.restoredTTYs.count)/\(state.plan.members.count)개 · Session ID 확인 중"
        case .groups:detail="그룹 소속·Goal·자동 승인 설정을 복원하고 있습니다."
        case .completed:detail="같은 대화의 연결과 그룹·자동 승인 설정 복원을 확인했습니다."
        case .cancelled:detail="이동 준비를 취소했습니다. 세션을 종료하지 않았습니다."
        }
        return .init(detail:detail,complete:state.phase == .completed,canCancel:state.phase == .captured)
    }
    public func performCodexSessionMove(id:String) async throws->CodexSessionAttachment {
        if let uuid=UUID(uuidString:id),try cohortRestartDriver().state(uuid) != nil {
            return try await performCodexCohortMove(uuid)
        }
        try CodexFeatureSupport.requireSessionMove()
        guard codexMigrationRunningIDs.insert(id).inserted else {
            throw AppError.message("이 이동의 실행·재연결 확인이 이미 진행 중입니다.")
        }
        defer{codexMigrationRunningIDs.remove(id)}
        guard codexMigrationReconnectContexts[id] != nil else {
            throw AppError.message("원래 터미널로 돌아올 이동 준비 정보를 확인하지 못했습니다.")
        }
        let coordinator=try sessionMigrationCoordinator()
        guard let state=try coordinator.state(id:id) else{throw AppError.message("준비한 이동을 찾지 못했습니다.")}
        if state.stage != .completed {_ = try await executeCodexSessionMigration(id:id)}
        return try await reconnectMigratedCodexSession(id:id)
    }
    private func cohortContext(_ id:UUID)throws->CodexCohortRestartContext {
        guard let text=store.value(CodexCohortRestartContext.key(id)) else{throw AppError.message("재시작 전의 터미널 복원 정보가 없습니다.")}
        let context=try JSONDecoder().decode(CodexCohortRestartContext.self,from:Data(text.utf8))
        guard context.planID==id else{throw AppError.message("세션 이동 요청의 복원 정보가 다릅니다.")}
        return context
    }
    private func scheduleCohortRecovery() {
        guard !remoteInputStopped,!snapshot.paused,Date()>=nextCohortRecovery else{return}
        nextCohortRecovery=Date().addingTimeInterval(30)
        guard let active=try? cohortRestartDriver().active() else{return}
        for state in active where cohortExecutionTasks[state.plan.id]==nil && !cohortRecoveryScheduled.contains(state.plan.id) {
            let id=state.plan.id
            Task { [weak self] in
                await self?.recoverCodexCohortMove(id)
            }
        }
    }
    public func recoverCodexCohortMoves() async {
        guard !remoteInputStopped,!snapshot.paused,let pending=try? cohortRestartDriver().active() else{return}
        for state in pending {await recoverCodexCohortMove(state.plan.id)}
    }
    private func recoverCodexCohortMove(_ id:UUID) async {
        guard !Task.isCancelled,!remoteInputStopped,!snapshot.paused,cohortExecutionTasks[id]==nil,
              !cohortRecoveryScheduled.contains(id),let state=try? cohortRestartDriver().state(id),
              state.phase != .cancelled,state.phase != .completed else{return}
        cohortRecoveryScheduled.insert(id);defer{cohortRecoveryScheduled.remove(id)}
        if state.phase == .captured {
            guard (try? cohortContext(id).automaticEnrollment)==true,
                  !officialAttachmentHomes.contains(state.plan.sourceHome) else{return}
            // No stop/launch can precede the durable .stopping transition.
            // Re-evaluate idle state, drafts, Goal and Session ID through a new
            // automatic proposal instead of replaying stale preparation.
            do {
                try cohortRestartDriver().cancel(id)
                cohortHeldSessionIDs.subtract(state.plan.members.map(\.runtimeID))
            }catch{}
            return
        }
        cohortHeldSessionIDs.formUnion(state.plan.members.map(\.runtimeID))
        _=try? await performCodexCohortMove(id)
    }
    private func saveCohortContext(_ context:CodexCohortRestartContext)throws {
        try store.set(CodexCohortRestartContext.key(context.planID),String(decoding:JSONEncoder().encode(context),as:UTF8.self))
    }
    private func performCodexCohortMove(_ id:UUID) async throws->CodexSessionAttachment {
        guard let initial=try cohortRestartDriver().state(id),initial.phase != .cancelled else{throw AppError.message("유효한 세션 이동 준비가 없습니다.")}
        let context=try cohortContext(id),plan=initial.plan
        if initial.phase == .captured {
            let originalPeer=try await Task.detached(priority:.utility){try CodexOfficialExecutable.verifyServer(CodexQueueConnection(home:plan.sourceHome))}.value
            guard originalPeer==context.originalServer else{throw AppError.message("준비한 뒤 서버가 바뀌었습니다. 세션을 종료하지 않고 준비를 다시 확인합니다.")}
            for member in plan.members {
                guard let session=sessions[member.runtimeID],session.phase != .ended,
                      let entry=plan.original.entries.first(where:{$0.id==member.entryID}),
                      try await statusConversationID(session)==entry.conversationID else {
                    throw AppError.message("준비한 뒤 현재 대화가 바뀌었습니다. 준비를 취소하고 다시 확인해주세요.")
                }
            }
        }
        let execution:Task<CodexCohortRestartState,Error>
        if let current=cohortExecutionTasks[id] {execution=current}
        else {
            cohortHeldSessionIDs.formUnion(plan.members.map(\.runtimeID))
            execution=Task { [self] in
                let deadline=Date().addingTimeInterval(180)
                var state=initial
                repeat {
                    try Task.checkCancellation()
                    state=try await cohortRestartDriver().advance(id,services:cohortRuntimeServices(id,plan:plan))
                    if state.phase == .completed {cohortHeldSessionIDs.subtract(plan.members.map(\.runtimeID));return state}
                    try await Task.sleep(for:.seconds(1))
                }while Date()<deadline
                return state
            }
            cohortExecutionTasks[id]=execution
        }
        defer{cohortExecutionTasks.removeValue(forKey:id)}
        let state=try await withTaskCancellationHandler(operation:{try await execution.value},onCancel:{execution.cancel()})
        guard let selected=plan.members.first(where:{$0.runtimeID==context.selectedSessionID}),let original=context.originals[selected.entryID] else{throw AppError.message("선택한 원래 터미널의 복원 정보를 찾지 못했습니다.")}
        var result=CodexSessionAttachment(context:original,home:plan.destinationHome)
        result.executionMode = .server
        result.phase=state.phase == .completed ? .connected:.verifying
        result.detail=state.phase == .completed ? "선택한 터미널의 이동과 관련 터미널·그룹 재연결을 확인했습니다.":"원래 터미널에서 같은 대화가 연결되는지 확인 중입니다. 저장된 요청으로 복원을 계속할 수 있습니다."
        if state.phase == .completed {try saveCodexSessionAttachment(result)}
        return result
    }
    private func cohortRuntimeServices(_ id:UUID,plan:CodexCohortRestartPlan)throws->CodexCohortRestartServices {
        let reader=processReader,database=paths.database
        return .init(validate:{[self] in
            try Task.checkCancellation()
            guard !remoteInputStopped,!snapshot.paused else{throw CancellationError()}
            let rows=try await Task.detached(priority:.utility){try reader()}.value
            guard let state=try cohortRestartDriver().state(id) else{throw AppError.message("재시작 진행 기록이 없습니다.")}
            for member in plan.members {
                if let live=rows.first(where:{$0.pid==member.pid && $0.started==member.started}) {
                    guard live.agent == .codex,"/dev/"+live.tty==member.tty else{throw AppError.message("원래 프로세스의 프로그램이나 터미널이 바뀌었습니다. 다른 프로그램은 종료하지 않았습니다.")}
                }
                let cli=rows.filter{$0.agent == .codex && "/dev/"+$0.tty==member.tty && $0.isForeground}
                if state.phase == .captured || state.phase == .stopping {
                    guard cli.allSatisfy({$0.key==member.runtimeID}) else{throw AppError.message("원래 터미널에 다른 Codex가 실행되어 중단하지 않았습니다.")}
                } else if state.phase == .restarting || state.phase == .transferring {
                    guard cli.isEmpty else{throw AppError.message("복원 전에 원래 터미널에서 새 Codex가 시작됐습니다. 새 작업은 중단하지 않았습니다.")}
                }
            }
        },originalAlive:{[self] member in
            let context=try cohortContext(id)
            let rows=try await Task.detached(priority:.utility){try reader()}.value
            return rows.contains(where:{$0.key==member.runtimeID}) || !CodexCohortProcessFence.live(context.processTree?[member.entryID] ?? [],records:rows).isEmpty
        },stop:{[self] member in
            let terminate=processTerminator
            var context=try cohortContext(id)
            let expected=context.originals[member.entryID]?.codexLaunch?.executable
            let rows=try await Task.detached(priority:.utility){try reader()}.value
            let owned=try CodexCohortProcessFence.capture(rootID:member.runtimeID,records:rows,previous:context.processTree?[member.entryID] ?? [])
            if context.processTree?[member.entryID] != owned {
                if context.processTree==nil {context.processTree=[:]}
                context.processTree?[member.entryID]=owned
                try saveCohortContext(context)
            }
            try await Task.detached(priority:.utility) {
                if let original=try reader().first(where:{$0.key==member.runtimeID && "/dev/"+$0.tty==member.tty}) {
                    guard original.agent == .codex,let expected,ProcessEnvironment.executablePath(original)==expected else{throw AppError.message("원래 Codex 실행 파일이 바뀌어 종료 요청을 보내지 않았습니다.")}
                    if !terminate(original),try reader().contains(where:{$0.key==original.key}) {throw AppError.message("원래 Codex의 종료 요청을 전달하지 못했습니다.")}
                }
                for witness in owned where witness.key != member.runtimeID {
                    guard let current=try reader().first(where:{$0.key==witness.key}) else{continue}
                    if !terminate(current),try reader().contains(where:{$0.key==current.key}) {throw AppError.message("원래 Codex의 하위 작업 종료를 기다리고 있습니다.")}
                }
            }.value
        },serverRestarted:{[self] in
            let context=try cohortContext(id)
            return try await Task.detached(priority:.utility){try CodexCohortRuntime.restarted(context,plan:plan)}.value
        },restartServer:{[self] in
            let context=try cohortContext(id)
            let updated=try await CodexCohortRuntime.restart(context,plan:plan,save:{[self] value in
                try await MainActor.run {guard !self.remoteInputStopped else{throw CancellationError()};try self.saveCohortContext(value)}
            })
            try saveCohortContext(updated)
        },transferComplete:{[self] in
            try await CodexCohortRuntime.transferred(cohortContext(id),plan:plan,database:database)
        },advanceTransfer:{[self] in
            try await CodexCohortRuntime.transfer(cohortContext(id),plan:plan,database:database)
        },observeRestored:{[self] entry,member in
            await refreshDiscovery()
            let rows=try await Task.detached(priority:.utility){try reader()}.value
            let matches=rows.filter{$0.agent == .codex && $0.isForeground && "/dev/"+$0.tty==member.tty && $0.key != member.runtimeID}
            guard matches.count==1,let record=matches.first,let current=sessions[record.key],let home=entry.providerHome else{return nil}
            let correct=try await Task.detached(priority:.utility) {
                let peer=try CodexOfficialExecutable.verifyServer(CodexQueueConnection(home:home))
                return CodexServerLocation.connectedHome(pid:record.pid,hints:[home],peerPID:Int32(peer.pid))==(try CodexAccountTransitionTarget.canonicalHome(home))
            }.value
            guard correct else{return nil}
            if try await leaveCohortGoalPaused(current,entry:entry,context:cohortContext(id)){return nil}
            guard let observed=try? await statusConversationID(current) else{return nil}
            guard observed==entry.conversationID else{throw AppError.message("복원된 터미널의 현재 대화가 저장한 대화와 다릅니다. 실행을 반복하지 않았습니다.")}
            groupStatusIdentities[current.id] = GroupStatusIdentity(session: current, conversationID: observed, home: home)
            return member.tty
        },restore:{[self] entry,member in
            let context=try cohortContext(id)
            guard let original=context.originals[member.entryID],let host=ScreenHost(kind:original.session.terminal),let adapter=screenAdapters[host],let restart=adapter.restart else{throw AppError.message("원래 터미널의 실행 경로를 확인하지 못했습니다.")}
            let rows=try await Task.detached(priority:.utility){try reader()}.value
            guard let shell=original.verifiedShell(in:rows) else{throw RemoteHTTPError(409,"원래 터미널의 빈 셸을 기다리고 있습니다.",diagnostics:["delivery":"not_started"])}
            let target=ScreenTarget(tty:member.tty,handle:original.session.screenHandle,jobPIDs:[shell.pid],sourcePID:shell.pid,sourceStarted:shell.started)
            let frame=try await Task.detached(priority:.utility){try adapter.readForValidation([target]).screens.first(where:{$0.tty==member.tty})?.contents}.value
            guard let frame,SessionExitRecovery.emptyShellPrompt(frame),let home=entry.providerHome else{throw RemoteHTTPError(409,"원래 셸의 빈 입력창을 기다리고 있습니다.",diagnostics:["delivery":"not_started"])}
            let command=try await Task.detached(priority:.utility) {
                var environment=ProcessInfo.processInfo.environment
                if let path=context.launch.path {environment["PATH"]=path}
                guard let cli=try CodexOfficialExecutable.resolve(home:home,userHome:context.launch.userHome,executable:context.launch.executable,environment:environment) else{throw AppError.message("공식 Codex CLI를 찾지 못했습니다.")}
                let args=try cli.terminalInvocation(["--remote","unix://","resume",entry.conversationID])
                return "cd -- "+HookInstaller.quote(entry.cwd)+" && "+args.map(HookInstaller.quote).joined(separator:" ")
            }.value
            let delivery=try await Task.detached(priority:.utility){try restart(target,frame,command)}.value
            guard delivery == .sent else{throw RemoteHTTPError(409,"화면이 바뀌어 복원 명령을 전달하지 않았습니다.",diagnostics:["delivery":"not_started"])}
        },restoreGroups:{[self] profile,ttys in
            let context=try cohortContext(id)
            let results=profile.entries.compactMap{entry in ttys[entry.id].map{TerminalProfileRestoreResult(id:entry.id,phase:.opened,detail:"같은 대화 연결 확인",tty:$0)}}
            let previous=plan.members.compactMap{member in plan.original.entries.first(where:{$0.id==member.entryID}).map{TerminalProfileCandidate(id:member.runtimeID,entry:$0,tty:member.tty)}}
            try await restoreTerminalProfileGroups(profile,results:results,previous:previous)
            try await CodexCohortRuntime.resumeGoals(context,plan:plan)
            for member in plan.members {
                guard let original=context.originals[member.entryID],let tty=ttys[member.entryID],
                      let current=sessions.values.first(where:{$0.tty==tty && $0.agent == .codex && $0.phase != .ended && $0.id != member.runtimeID}),
                      let entry=profile.entries.first(where:{$0.id==member.entryID}) else{throw AppError.message("그룹 복원 뒤 현재 터미널 연결을 확인하지 못했습니다.")}
                try await connectCodexApprovals(sessionID:current.id,threadID:entry.conversationID)
                guard let host=ScreenHost(kind:current.terminal),screenConnections[host]?.enabled==true else{throw AppError.message("복원한 원래 터미널의 화면 연결이 끊겼습니다.")}
                let frame=try await remoteTerminal(sessionID:current.id,realtime:true,textOnly:true)
                // Discovery creates a new runtime with no monitor channel. Do
                // not race the next background poll when restoring its opt-in.
                try Task.checkCancellation()
                guard !remoteInputStopped,!snapshot.paused,screenConnections[host]?.enabled==true,
                      let live=sessions[current.id],live.pid==current.pid,live.started==current.started,
                      live.tty==current.tty,live.phase != .ended else{throw AppError.message("자동 승인 설정을 복원하기 전에 원래 터미널 연결이 바뀌었습니다.")}
                sessions[current.id]?.channel=host.channel
                receiveScreen(sessionID:current.id,raw:frame.screen,generation:remoteGeneration(current,host:host),source:host.channel)
                try setAutomatic(current.id,enabled:original.session.automatic)
            }
        })
    }
    /// The official TUI can ask to resume a paused Goal on cold selection.
    /// Dismiss only this exact chooser, retaining the verified Goal instance;
    /// original active Goals resume later through the lifecycle coordinator.
    private func leaveCohortGoalPaused(_ original:AgentSession,entry:TerminalProfileEntry,context:CodexCohortRestartContext) async throws->Bool {
        guard let expected=context.originalGoals[entry.conversationID],let home=entry.providerHome,
              let host=ScreenHost(kind:original.terminal),screenConnections[host]?.enabled==true,
              let adapter=screenAdapters[host] else{return false}
        let frame=try await remoteTerminal(sessionID:original.id,realtime:true,textOnly:true)
        let raw=frame.screen
        guard raw.contains("Resume paused goal?"),raw.contains("Mark it active and continue when idle"),
              raw.contains("Keep it paused; use /goal resume later"),raw.contains("esc back") else{return false}
        guard !nativeUserInputHasPriority(original.id),!remoteUserInputHasPriority(original.id),!automaticInputBusy(original.id),
              !remoteInputStopped,!snapshot.paused else{return true}
        let goal=try await Task.detached(priority:.utility) {
            let connection=try CodexQueueConnection(home:home)
            _=try CodexOfficialExecutable.verifyServer(connection)
            return try CodexGoalTransport.readWithIdentity(connection,home:home,threadID:entry.conversationID)
        }.value
        guard let goal,let instance=expected.instanceID,goal.instanceID==instance,goal.status == .paused,
              goal.objective==expected.objective,goal.createdAt==expected.createdAt,goal.tokenBudget==expected.tokenBudget,
              goal.tokensUsed>=expected.tokensUsed,goal.timeUsedSeconds>=expected.timeUsedSeconds else {
            throw AppError.message("복원한 Goal의 신원·일시정지 상태가 바뀌어 재개 선택창에 입력하지 않았습니다.")
        }
        try Task.checkCancellation()
        guard let current=sessions[original.id],current.pid==original.pid,current.started==original.started,
              current.tty==original.tty,current.phase != .ended,!remoteInputStopped,!snapshot.paused,
              !nativeUserInputHasPriority(original.id),!remoteUserInputHasPriority(original.id) else{return true}
        let verify=remoteProcessVerifier
        let target=ScreenTarget(tty:current.tty,handle:current.screenHandle,jobPIDs:[current.pid],sourcePID:current.pid,sourceStarted:current.started)
        let result=try await Task.detached(priority:.utility) {
            guard try verify(current) else{throw AppError.message("복원한 Codex 프로세스가 바뀌었습니다.")}
            return try adapter.input(target,raw,.codex,.init(kind:.escape))
        }.value
        guard result == .sent else{throw RemoteHTTPError(409,"Goal 재개 선택창이 바뀌어 입력하지 않았습니다.",diagnostics:["delivery":"not_started"])}
        return true
    }
    func codexMigrationReconnectContext(sessionID:String,request:CodexSessionMigrationRequest) async throws->SessionExitRecovery {
        guard let session=sessions[sessionID],session.phase != .ended,session.agent == .codex,
              let host=ScreenHost(kind:session.terminal),screenConnections[host]?.enabled==true,
              screenAdapters[host]?.restart != nil,
              request.clients.contains(where:{$0.identity.pid==session.pid && $0.identity.started==session.started
                  && $0.identity.tty==session.tty}) else {
            throw AppError.message("이동 후 돌아올 원래 세션과 터미널 연결을 확인해주세요.")
        }
        let runtime=try await codexNativeRuntime(sessionID:sessionID)
        let active=runtime.connection.tuiActiveThreadIDs
        guard active.count==1,let thread=active.first,request.threads.contains(where:{$0.id==thread && $0.parentID==nil}) else {
            throw AppError.message("이동 후 재개할 현재 부모 대화를 확인하지 못했습니다.")
        }
        let reader=processReader
        let records=try await Task.detached(priority:.utility){try reader()}.value
        guard let process=records.first(where:{$0.pid==session.pid && $0.started==session.started}),process.isForeground,
              let shell=ProcessDiscovery.ancestors(of:process.parent,byPID:ProcessDiscovery.index(records))
                .first(where:{$0.tty==process.tty && SessionExitRecovery.isShell($0)}),
              !CodexSessionAttachment.hasIndependentChildWork(process:process,records:records),
              let current=sessions[sessionID],current.pid==session.pid,current.started==session.started,current.phase != .ended else {
            throw AppError.message("원래 Codex의 셸이나 실행 중인 하위 작업을 확인해주세요.")
        }
        var context=SessionExitRecovery(session:session,process:process,shell:shell,conversationID:thread)
        context.executable=request.source.cliIdentity
        context.codexLaunch=try await Task.detached(priority:.utility){try CodexSessionLaunch.capture(process)}.value
        return context
    }
    /// Internal until the caller also owns the terminal reconnection lifecycle.
    func reconnectMigratedCodexSession(id:String) async throws->CodexSessionAttachment {
        guard let context=codexMigrationReconnectContexts[id],let moved=try sessionMigrationCoordinator().state(id:id),
              moved.stage == .completed,let host=ScreenHost(kind:context.session.terminal),
              screenConnections[host]?.enabled==true,let adapter=screenAdapters[host],let restart=adapter.restart else {
            throw AppError.message("완료된 이동과 원래 터미널의 재연결 정보를 확인해주세요.")
        }
        let key="codexMigrationReconnectPlan:"+id
        let destinationHome=moved.request.destination.home,threadIDs=moved.request.threads.map(\.id)
        let executionMode:CodexSessionAttachment.ExecutionMode = try codexIndependentLoginStore.requiresStandalone(home:destinationHome) ? .standalone:.server
        let sourceConnectionHome=try CodexAccountTransitionTarget.canonicalHome(moved.request.source.home)
        let destinationConnectionHome=try CodexAccountTransitionTarget.canonicalHome(destinationHome)
        try await Task.detached(priority:.utility) {
            let connection=try CodexQueueConnection(home:destinationHome)
            _ = try CodexOfficialExecutable.verifyServer(connection)
            for thread in threadIDs {
                try Task.checkCancellation()
                let response=try connection.request("thread/read",["threadId":thread,"includeTurns":false])
                guard let row=response["thread"] as? JSONObject,row["id"] as? String==thread,let path=row["path"] as? String else {
                    throw AppError.message("목적지 대화의 보관 상태를 확인하지 못했습니다.")
                }
                if path.contains("/archived_sessions/") {
                    _=try connection.request("thread/unarchive",["threadId":thread],classifyError:true)
                }
            }
        }.value
        var plan:CodexSessionAttachment
        if let saved=store.value(key),!saved.isEmpty {plan=try JSONDecoder().decode(CodexSessionAttachment.self,from:Data(saved.utf8))}
        else {plan=try CodexSessionAttachment.migrated(context:context,state:moved,executionMode:executionMode)}
        guard (plan.executionMode ?? .server)==executionMode else {
            throw AppError.message("저장한 재연결 방식과 목적지 홈이 다릅니다. 실행 명령을 반복하지 않았습니다.")
        }
        let original=context.session,reader=processReader,epoch=codexAccountTransitionEpoch
        if plan.context.codexLaunch==nil,![.launchReserved,.verifying,.connected,.review].contains(plan.phase) {
            let savedContext=context
            plan.context.codexLaunch=try await Task.detached(priority:.utility) {
                try CodexSessionLaunch.forAttachment(savedContext,home:destinationHome,records:reader())
            }.value
            try store.set(key,String(decoding:JSONEncoder().encode(plan),as:UTF8.self))
        }
        let launchAttachment=plan
        let resolveRuntime=codexAttachmentRuntime
        // Attest before sending /exit. A failed replacement leaves the original
        // session open and the durable delivery receipt unchanged.
        let preflight:CodexCLIContext?
        if [.ready,.needsTab,.needsPause].contains(plan.phase) {
            guard let launchIdentity=launchAttachment.context.codexLaunch else{throw AppError.message("원래 Codex 실행 환경을 확인하지 못했습니다.")}
            preflight=try await resolveRuntime(launchIdentity,destinationHome,executionMode)
        }else{preflight=nil}
        func authorized()throws {
            try Task.checkCancellation()
            guard !remoteInputStopped,!snapshot.paused,epoch==codexAccountTransitionEpoch else{throw CancellationError()}
        }
        func screen(_ target:ScreenTarget) async throws->String {
            try authorized()
            let result=try await Task.detached(priority:.utility){try adapter.readForValidation([target])}.value
            guard result.failures.isEmpty,result.screens.count==1,let raw=result.screens.first?.contents else {
                throw AppError.message("재연결할 터미널 화면을 확인하지 못했습니다.")
            }
            try authorized();return raw
        }
        let target=ScreenTarget(tty:original.tty,handle:original.screenHandle,jobPIDs:[original.pid],sourcePID:original.pid,sourceStarted:original.started)
        let services=CodexSessionAttachmentServices(exit:{
            try authorized()
            try preflight?.verifyUnchanged()
            let rows=try await Task.detached(priority:.utility){try reader()}.value
            guard let process=rows.first(where:{$0.pid==original.pid && $0.started==original.started}),process.isForeground,
                  !CodexSessionAttachment.hasIndependentChildWork(process:process,records:rows),
                  CodexServerLocation.connectedHome(pid:process.pid,hints:[sourceConnectionHome])==sourceConnectionHome else {
                throw AppError.message("이동한 원본 Codex의 실행·서버 연결이 바뀌었습니다.")
            }
            let before=try await screen(target)
            guard CodexGoalScreen.ready(before) else{throw AppError.message("원본 Codex의 작업·질문·작성 중 입력을 확인해주세요.")}
            // Explicit paste avoids Codex treating a fast text+Enter burst as
            // multiline draft input and leaving /exit unsubmitted.
            return try await Task.detached(priority:.utility){try adapter.input(target,before,.codex,.init(kind:.message,text:"/exit")) == .sent}.value
        },shellReady:{
            let rows=try await Task.detached(priority:.utility){try reader()}.value
            guard let shell=context.verifiedShell(in:rows) else{return false}
            let target=ScreenTarget(tty:original.tty,handle:original.screenHandle,jobPIDs:[shell.pid],sourcePID:shell.pid,sourceStarted:shell.started)
            return SessionExitRecovery.emptyShellPrompt(try await screen(target))
        },launch:{
            let rows=try await Task.detached(priority:.utility){try reader()}.value
            guard let shell=context.verifiedShell(in:rows) else{throw AppError.message("원래 빈 셸을 확인하지 못했습니다.")}
            guard let launchIdentity=launchAttachment.context.codexLaunch else{throw AppError.message("원래 Codex 실행 환경을 확인하지 못했습니다.")}
            let cli=try await resolveRuntime(launchIdentity,destinationHome,executionMode)
            if executionMode == .standalone {
                try await self.disableIndependentDaemonAutoStart(home:destinationHome,executable:cli.executable)
            }
            let command=try launchAttachment.command(using:cli)
            let target=ScreenTarget(tty:original.tty,handle:original.screenHandle,jobPIDs:[shell.pid],sourcePID:shell.pid,sourceStarted:shell.started)
            let before=try await screen(target)
            guard SessionExitRecovery.emptyShellPrompt(before) else{throw AppError.message("셸 입력창이 비어 있지 않습니다.")}
            try cli.verifyUnchanged()
            return try await Task.detached(priority:.utility){try restart(target,before,command) == .sent}.value
        },verify:{
            try authorized()
            let rows=try await Task.detached(priority:.utility){try reader()}.value
            let candidates=rows.filter{$0.agent == .codex && $0.tty==context.shell.tty && $0.key != original.id
                && ProcessDiscovery.ancestors(of:$0.parent,byPID:ProcessDiscovery.index(rows)).contains(where:{$0.key==context.shell.key})}
            guard candidates.count==1,let next=candidates.first,let thread=context.conversationID else{return false}
            let connected=CodexServerLocation.connectedHome(pid:next.pid,hints:[destinationConnectionHome])
            let loaded:Bool
            if executionMode == .standalone {
                guard connected==nil else{return false}
                loaded=await Task.detached(priority:.utility){
                    guard let location=try? CodexThreadLocation.locate(paths:ProcessOpenFiles.codexRolloutPaths(pid:next.pid,expectedStart:next.started)) else{return false}
                    return location.threadID==thread && (try? CodexAccountTransitionTarget.canonicalHome(URL(fileURLWithPath:location.database).deletingLastPathComponent().path))==destinationConnectionHome
                }.value
            }else {
                guard connected==destinationConnectionHome else{return false}
                loaded=try await Task.detached(priority:.utility){
                let response=try CodexQueueConnection(home:moved.request.destination.home).request("thread/read",["threadId":thread,"includeTurns":false])
                guard let row=response["thread"] as? JSONObject else{return false}
                return row["id"] as? String==thread && CodexQueueTransport.isLoadedRoot(row,cwd:original.cwd)
                }.value
            }
            guard loaded else{return false}
            try self.store.set("automatic:"+next.key,original.automatic ? "true":"false")
            self.sessions[next.key]?.automatic=original.automatic
            return true
        })
        if [.review,.launchReserved,.verifying,.connected].contains(plan.phase),try await services.verify() {
            plan.phase = .connected
            plan.detail="실행 명령을 반복하지 않고 목적지의 같은 대화 연결을 확인했습니다."
            try store.set(key,String(decoding:JSONEncoder().encode(plan),as:UTF8.self))
            try saveCodexMigrationReconnectContext(nil,id:id)
            return plan
        }
        repeat {
            plan=try await services.advance(plan,save:{value in
                try self.store.set(key,String(decoding:JSONEncoder().encode(value),as:UTF8.self))
            })
            if plan.phase == .connected {try saveCodexMigrationReconnectContext(nil,id:id);return plan}
            if plan.phase == .review {return plan}
            try await Task.sleep(for:.seconds(1))
        }while true
    }
    func executeCodexSessionMigration(id:String) async throws->CodexSessionMigrationState {
        try CodexFeatureSupport.requireSessionMove()
        guard !remoteInputStopped,!codexAccountTransitionBusy,!codexAccountTransitionHeld,!agentAccounts.busy else {
            throw AppError.message("진행 중인 로그인·계정 전환을 마친 뒤 이동해주세요.")
        }
        let coordinator=try sessionMigrationCoordinator()
        guard let state=try coordinator.state(id:id),state.stage == .prepared,state.execution==nil else {
            throw AppError.message("준비된 이동을 확인하지 못했습니다. 이전 실행을 반복하지 않습니다.")
        }
        let epoch=codexAccountTransitionEpoch
        codexAccountTransitionBusy=true
        defer{refreshCodexMigrationHolds();if epoch==codexAccountTransitionEpoch{codexAccountTransitionBusy=false}}
        @Sendable func runtime(_ endpoint:CodexMigrationEndpoint) async throws->CodexNativeServerRuntime {
            guard let component=endpoint.serverID.split(separator:":").first,let pid=Int32(component),pid>0 else {
                throw AppError.message("이동 서버의 프로세스를 확인하지 못했습니다.")
            }
            return try await CodexNativeServerRuntime.resolve(home:endpoint.home,serverPID:pid)
        }
        async let sourceRuntime=runtime(state.request.source)
        async let destinationRuntime=runtime(state.request.destination)
        let (source,destination)=try await (sourceRuntime,destinationRuntime)
        guard epoch==codexAccountTransitionEpoch,!remoteInputStopped else{throw CancellationError()}
        var clientHolds:[CodexNativeTerminalInputHold]=[]
        defer{for hold in clientHolds{try? hold.release();hold.close()}}
        for client in state.request.clients {
            let pair=try await CodexNativeRuntimePair.resolve(home:client.home,tuiPID:client.identity.pid,serverPID:Int32(source.peer.pid))
            let hold=try CodexNativeTerminalInputHold(path:pair.tuiControlSocket,expected:pair.connection)
            try hold.pause()
            clientHolds.append(hold)
        }
        let ids=state.request.threads.map(\.id)
        let sourceLease=try CodexNativeSelectedInputLease(path:source.controlSocket,expectedServerPeer:source.peer,threadIDs:ids)
        defer{sourceLease.close()}
        let destinationLease=try CodexNativeSelectedInputLease(path:destination.controlSocket,expectedServerPeer:destination.peer,threadIDs:ids)
        defer{destinationLease.close()}
        return try await coordinator.executePrepared(id:id,source:source,destination:destination,
            sourceLease:sourceLease,destinationLease:destinationLease,clientHolds:clientHolds)
    }
    func codexNativeDestinationServer(home:String) async throws->CodexNativeServerRuntime {
        let canonical=try CodexAccountTransitionTarget.canonicalHome(home)
        let standard=try CodexAccountTransitionTarget.canonicalHome(NSHomeDirectory()+"/.codex")
        let groups=try await codexLoginGroups()
        let independent=try await codexIndependentLogins()
        guard canonical==standard || groups.contains(where:{(try? CodexAccountTransitionTarget.canonicalHome($0.home))==canonical})
                || independent.contains(where:{(try? CodexAccountTransitionTarget.canonicalHome($0.home))==canonical}) else {
            throw AppError.message("대상 로그인 그룹을 다시 선택해주세요.")
        }
        let (identity,server)=try await CodexServerAccountIdentity.read(home:canonical)
        guard identity.authenticated,server>0,!remoteInputStopped else {
            throw AppError.message("대상 로그인 그룹의 실행 서버와 계정을 확인해주세요.")
        }
        _ = try await Task.detached(priority:.utility){try CodexNativeRuntimeRoot.prepare()}.value
        let runtime=try await CodexNativeServerRuntime.resolve(home:canonical,serverPID:server)
        guard runtime.peer.pid==UInt32(server),runtime.peer.effectiveUid==getuid(),runtime.peer.auditPidVersion>0 else {
            throw AppError.message("대상 그룹의 네이티브 서버 연결을 확인하지 못했습니다.")
        }
        return runtime
    }
    func codexMigrationRequest(sessionID:String,destinationHome:String) async throws->CodexSessionMigrationRequest {
        guard let session=sessions[sessionID],session.agent == .codex,session.phase != .ended else {
            throw AppError.message("이동할 Codex 세션을 선택해주세요.")
        }
        let account=try await codexSessionAccount(sessionID:sessionID)
        let pair=try await codexNativeRuntime(sessionID:sessionID)
        let source=try await CodexNativeServerRuntime.resolve(home:account.target.home,serverPID:Int32(pair.connection.serverPeer.pid))
        let destination=try await codexNativeDestinationServer(home:destinationHome)
        let (destinationAccount,_)=try await CodexServerAccountIdentity.read(home:destinationHome)
        let reader=processReader
        let records=try await Task.detached(priority:.utility){try reader()}.value
        guard let process=records.first(where:{$0.pid==session.pid && $0.started==session.started}) else {
            throw AppError.message("이동할 세션의 프로세스가 바뀌었습니다.")
        }
        let sourceEndpoint=try CodexMigrationEndpoint.capture(home:account.target.home,runtime:source,account:account.identity)
        let home=sourceEndpoint.home
        let client=try pair.connection.migrationClient(process:process,home:home)
        let roots=client.threadIDs
        let threads=try await Task.detached(priority:.utility) {
            try CodexMigrationThread.captureScope(connection:CodexQueueConnection(home:home),home:home,rootIDs:roots)
        }.value
        guard !remoteInputStopped,let current=sessions[sessionID],current.pid==session.pid,
              current.started==session.started,current.phase != .ended else{throw CancellationError()}
        return .init(id:UUID().uuidString.lowercased(),
            source:sourceEndpoint,
            destination:try CodexMigrationEndpoint.capture(home:destinationHome,runtime:destination,account:destinationAccount),
            clients:[client],threads:threads)
    }
    func codexMigrationObservation(_ request:CodexSessionMigrationRequest) async throws->CodexSessionMigrationObservation {
        let reader=processReader
        let records=try await Task.detached(priority:.utility){try reader()}.value
        let targets=try await codexAccountTargetReader(records)
        var endpoints:[CodexMigrationEndpoint]=[],clients:[CodexMigrationClient]=[]
        for home in [request.source.home,request.destination.home] {
            try validateCodexLoginHome(home)
            let (account,pid)=try await CodexServerAccountIdentity.read(home:home)
            let runtime=try await CodexNativeServerRuntime.resolve(home:home,serverPID:pid)
            endpoints.append(try CodexMigrationEndpoint.capture(home:home,runtime:runtime,account:account))
            let canonical=try CodexAccountTransitionTarget.canonicalHome(home)
            let witnesses=targets.first(where:{$0.home==canonical})?.witnesses ?? []
            if !witnesses.isEmpty {
                let census=try await CodexNativeRuntimePair.resolveCensus(home:home,serverPID:pid,clientPIDs:witnesses.map(\.pid))
                for pair in census {
                    guard let process=records.first(where:{UInt32($0.pid)==pair.connection.tuiPeer.pid}),
                          witnesses.contains(where:{$0.pid==process.pid && $0.started==process.started}) else {
                        throw AppError.message("이동 준비 중 Codex 세션 연결이 바뀌었습니다.")
                    }
                    clients.append(try pair.connection.migrationClient(process:process,home:home))
                }
            }else {
                let inventory=try await CodexNativeObservation.query(path:runtime.inventorySocket)
                let body=try JSONSerialization.jsonObject(with:inventory.data) as? JSONObject
                guard inventory.peer.identity==runtime.peer,let connections=body?["connections"] as? [JSONObject],connections.isEmpty else {
                    throw AppError.message("로그인 그룹 서버에 식별되지 않은 세션 연결이 있습니다.")
                }
            }
        }
        let home=request.source.home,roots=request.clients.flatMap(\.threadIDs)
        let threads=try await Task.detached(priority:.utility) {
            let connection=try CodexQueueConnection(home:home)
            return try CodexMigrationThread.captureScope(connection:connection,home:home,rootIDs:Array(Set(roots)))
        }.value
        try Task.checkCancellation()
        guard !remoteInputStopped else{throw CancellationError()}
        return .init(source:endpoints[0],destination:endpoints[1],clients:clients,threads:threads,
            completeClients:true,completeThreads:true)
    }
    public func createCodexLoginGroup(name:String) async throws->CodexLoginGroup {
        guard !remoteInputStopped else{throw CancellationError()}
        let store=codexLoginGroupStore
        let group=try await Task.detached(priority:.utility){try store.create(name:name)}.value
        objectWillChange.send()
        return group
    }
    public func renameCodexLoginGroup(id:UUID,name:String) async throws->CodexLoginGroup {
        try Task.checkCancellation()
        guard !remoteInputStopped else{throw CancellationError()}
        let store=codexLoginGroupStore
        let group=try await Task.detached(priority:.utility){try store.rename(id:id,name:name)}.value
        objectWillChange.send()
        return group
    }
    public func codexServerSetupHomes(includeStoredGroups:Bool=true) async throws -> [String] {
        let reader=processReader
        let records=try await Task.detached(priority:.utility){try reader()}.value
        try Task.checkCancellation()
        var homes=Set(records.filter{$0.agent == .codex}.compactMap {record in
            ProcessEnvironment.read(record)?["CODEX_HOME"].flatMap{try? CodexAccountTransitionTarget.canonicalHome($0)}
        })
        if includeStoredGroups {for group in try await codexLoginGroups(){homes.insert(try CodexAccountTransitionTarget.canonicalHome(group.home))}}
        // A detached session must not be silently enrolled again by discovery.
        for independent in try await codexIndependentLogins() {
            if !independent.usesDedicatedServer {homes.remove(try CodexAccountTransitionTarget.canonicalHome(independent.home))}
        }
        return homes.sorted()
    }
    /// One automatic attempt per home and manager lifetime, including failures.
    public func ensureCodexManagedServers() async {
        guard !Task.isCancelled,!remoteInputStopped,!codexAccountTransitionBusy,!codexAccountTransitionHeld,!agentAccounts.busy else{return}
        let epoch=codexAccountTransitionEpoch
        do {
            let homes=try await codexServerSetupHomes(includeStoredGroups:false)
            for home in Set(homes+[try CodexAccountTransitionTarget.canonicalHome(NSHomeDirectory()+"/.codex")]).sorted() {
                guard !Task.isCancelled,epoch==codexAccountTransitionEpoch,!remoteInputStopped,!codexAccountTransitionBusy,!codexAccountTransitionHeld,!agentAccounts.busy else{return}
                guard codexManagedServerAutomaticHomes.insert(home).inserted else{continue}
                do {
                    let status=try await codexManagedServerStatus(home:home)
                    guard epoch==codexAccountTransitionEpoch,!Task.isCancelled else{return}
                    let result=status.canPrepare ? try await prepareCodexManagedServer(home:home):status
                    guard epoch==codexAccountTransitionEpoch,!Task.isCancelled else{return}
                    if result.phase == .running {codexAttachmentHomes.insert(home)}
                    else {codexAccountTransitionNotice=result.detail}
                } catch is CancellationError {return}
                catch {if epoch==codexAccountTransitionEpoch {codexAccountTransitionNotice="관리형 Codex 서버 자동 준비를 완료하지 못했습니다. 계정·로그인에서 연결을 다시 확인해주세요."}}
            }
        } catch { /* Retry discovery before reserving a start. */ }
        for home in codexAttachmentHomes.sorted() {await attachStandaloneCodexSessions(home:home)}
    }
    private func identifyStandaloneCodex(_ original:AgentSession,home:String,adapter:ScreenHostAdapter,allowWorking:Bool=false,authorized:()->Bool) async throws->String? {
        let target=ScreenTarget(tty:original.tty,handle:original.screenHandle,jobPIDs:[original.pid],sourcePID:original.pid,sourceStarted:original.started)
        func read() async throws->String {
            guard authorized() else{throw CancellationError()}
            let result=try await Task.detached(priority:.utility){try adapter.readForValidation([target])}.value
            guard authorized(),result.failures.isEmpty,result.screens.count==1,let raw=result.screens.first?.contents else{throw AppError.message("원본 화면을 확인하지 못했습니다.")}
            return raw
        }
        let key="codexStatusIdentity:"+original.id,before=try await read()
        guard CodexGoalScreen.ready(before) || allowWorking && CodexGoalScreen.workingReady(before) else{return nil}
        var proof:CodexStatusIdentity
        let existing=store.value(key).flatMap{$0.data(using:.utf8)}.flatMap{try? JSONDecoder().decode(CodexStatusIdentity.self,from:$0)}
        if let existing,existing.threadID==nil {
            // An uncertain delivery is observed, never repeated after restart.
            proof=existing
        } else {
            if let existing,let thread=existing.threadID,existing.matches(before,thread:thread) {return thread}
            // A completed read may be refreshed after work changes the frame.
            try await Task.sleep(for:.milliseconds(350))
            let after=try await read()
            guard authorized(),after==before || allowWorking && CodexGoalScreen.workingReady(after) else{return nil}
            proof=CodexStatusIdentity(screen:after)
            try store.set(key,String(decoding:JSONEncoder().encode(proof),as:UTF8.self))
            let delivered=try await Task.detached(priority:.utility){try adapter.input(target,after,.codex,.init(kind:.message,text:"/status"))}.value
            guard delivered == .sent else{try store.set(key,"");return nil}
        }
        for _ in 0..<20 {
            guard authorized(),Date().timeIntervalSince(proof.requested)<120 else{return nil}
            let raw=try await read()
            if (CodexGoalScreen.ready(raw) || allowWorking && CodexGoalScreen.workingReady(raw)),proof.identify(raw) {
                try store.set(key,String(decoding:JSONEncoder().encode(proof),as:UTF8.self));return proof.threadID
            }
            try await Task.sleep(for:.milliseconds(200))
        }
        return nil
    }
    private func saveCodexSessionAttachment(_ state:CodexSessionAttachment) throws {
        let previous=codexSessionAttachments[state.context.session.id]
        var states=codexSessionAttachments;states[state.context.session.id]=state
        try store.set("codexSessionAttachments",String(decoding:JSONEncoder().encode(states),as:UTF8.self))
        codexSessionAttachments=states;codexSessionAttachmentNotice=state.detail
        if previous?.phase != state.phase || state.phase == .review && previous?.detail != state.detail {
            _ = log(AuditEvent(sessionID:state.context.session.id,summary:"Codex 세션 서버 연결",
                outcome:"["+state.phase.rawValue+"] "+state.detail,source:"세션 재연결",context:AuditContext(session:state.context.session)))
        }
    }
    /// Idle standalone conversations move sequentially through their own shell.
    /// Active work, Goals, questions and drafts wait without being discarded.
    func attachStandaloneCodexSessions(home:String,sessionIDs:Set<String>?=nil) async {
        guard CodexFeatureSupport.canAttachOpenStandaloneSessions else {
            codexAttachmentHomes.remove(home);codexSessionAttachmentNotice=CodexFeatureSupport.standaloneAttachmentUnavailable;return
        }
        await attachOfficialStandaloneCodexSessions(home:home,sessionIDs:sessionIDs)
    }
    /// Automatic enrollment waits for a fresh empty idle composer. Explicit
    /// moves use the same coordinator and can quiesce active work themselves.
    func attachOfficialStandaloneCodexSessions(home:String,sessionIDs:Set<String>?=nil,allowActive:Bool=false) async {
        guard !Task.isCancelled,!snapshot.paused,!remoteInputStopped,!codexAccountTransitionBusy,!codexAccountTransitionHeld,!agentAccounts.busy,
              officialAttachmentHomes.insert(home).inserted else{return}
        defer{officialAttachmentHomes.remove(home)}
        if sessionIDs==nil,(try? codexIndependentLoginStore.requiresStandalone(home:home))==true{return}
        do {
            let reader=processReader
            let rows=try await Task.detached(priority:.utility){try reader()}.value
            let connected=try await codexAccountTargetReader(rows)
            let connectedIDs=Set(connected.flatMap{$0.witnesses.map{"process:\($0.pid):\($0.started)"}})
            officialAttachmentRetryAfter=officialAttachmentRetryAfter.filter{key,_ in rows.contains(where:{$0.key==key})}
            let candidates=sessions.values.filter{$0.agent == .codex && $0.phase != .ended && !connectedIDs.contains($0.id) && (sessionIDs?.contains($0.id) ?? true)}.sorted{$0.pid<$1.pid}
            for original in candidates {
                guard !Task.isCancelled,!remoteInputStopped,!snapshot.paused else{return}
                guard (allowActive || Date()>=(officialAttachmentRetryAfter[original.id] ?? .distantPast)),!userInputHasPriority(original.id),
                      !automaticInputBusy(original.id),!codexAccountInputHeld(original.id),!original.pendingInTerminal,!original.needsReview,
                      let process=rows.first(where:{$0.key==original.id && $0.isForeground}),
                      let host=ScreenHost(kind:original.terminal),screenConnections[host]?.enabled==true,screenAdapters[host]?.restart != nil else{continue}
                let environment=ProcessEnvironment.read(process,names:["HOME","CODEX_HOME"])
                guard let selected=environment?["CODEX_HOME"] ?? environment?["HOME"].map({$0+"/.codex"}),
                      (try? CodexAccountTransitionTarget.canonicalHome(selected))==home else{continue}
                officialAttachmentRetryAfter[original.id]=Date().addingTimeInterval(30)
                let frame=try await remoteTerminal(sessionID:original.id,realtime:true,textOnly:true)
                guard (allowActive || ActivityDetector.detect(frame.screen,agent:.codex).phase == .idle),CodexStatusIdentity.canQuery(frame.screen) else {
                    codexAttachmentWaitReasons[original.id]="빈 입력창을 확인한 뒤 연결합니다. 작성 중인 입력·질문은 유지됩니다."
                    continue
                }
                let plan=try await prepareStandaloneCodexCohortMove(sessionID:original.id,destinationHome:home,automaticEnrollment:!allowActive)
                guard let id=UUID(uuidString:plan.id) else{throw AppError.message("자동 연결 요청의 식별자를 확인하지 못했습니다.")}
                let context=try cohortContext(id)
                if !allowActive && (context.originalGoals.values.contains(where:{$0.status == .active}) || context.scope.contains(where:{$0.active})) {
                    try cancelCodexSessionMove(id:plan.id)
                    codexAttachmentWaitReasons[original.id]="기존 Goal·하위 작업 유지 중 · 완료 후 자동 연결합니다. 세션 ID 조회와 명시적인 그룹 이동은 사용할 수 있습니다."
                    continue
                }
                let result=try await performCodexSessionMove(id:plan.id)
                if result.phase != .connected {codexSessionAttachmentNotice=result.detail}
                codexAttachmentWaitReasons.removeValue(forKey:original.id)
            }
        }catch is CancellationError {return}
        catch {codexSessionAttachmentNotice="공식 Codex 세션 연결 확인 필요: "+String(error.localizedDescription.prefix(240))}
    }
    private func attachLegacyStandaloneCodexSessions(home:String,sessionIDs:Set<String>?=nil) async {
        // The original-runtime flag must never enable the retired private IPC.
        guard CodexFeatureSupport.canUsePrivateSessionAttachment else {
            codexAttachmentHomes.remove(home)
            codexSessionAttachmentNotice=CodexFeatureSupport.standaloneAttachmentUnavailable
            return
        }
        guard !Task.isCancelled,!snapshot.paused,!remoteInputStopped,!codexAccountTransitionBusy,!codexAccountTransitionHeld,!agentAccounts.busy else{return}
        if sessionIDs==nil,(try? codexIndependentLoginStore.contains(home:home))==true {return}
        let epoch=codexAccountTransitionEpoch,reader=processReader
        codexAccountTransitionBusy=true
        defer {if epoch==codexAccountTransitionEpoch {codexAccountTransitionBusy=false};codexAttachmentActiveIDs.removeAll()}
        func authorized(_ id:String)->Bool {
            !Task.isCancelled && epoch==codexAccountTransitionEpoch && !remoteInputStopped && !snapshot.paused && !nativeUserInputHasPriority(id) && !remoteUserInputHasPriority(id)
        }
        do {
            guard try await codexManagedServerStatus(home:home).phase == .running else{return}
            var live=try await Task.detached(priority:.utility){try reader()}.value
            let connected=try await codexAccountTargetReader(live)
            let connectedIDs=Set(connected.flatMap{$0.witnesses.map{"process:\($0.pid):\($0.started)"}})
            var waiting=0,waitDetails:[String]=[]
            codexAttachmentWaitReasons=codexAttachmentWaitReasons.filter{key,_ in live.contains(where:{$0.key==key}) && !connectedIDs.contains(key)}
            func wait(_ session:AgentSession,_ reason:String) {
                waiting+=1;codexAttachmentWaitReasons[session.id]=reason
                waitDetails.append("• "+session.project+" · "+session.tty.replacingOccurrences(of:"/dev/",with:"")+": "+reason)
            }
            for original in snapshot.sessions.filter({$0.agent == .codex && $0.phase != .ended && !connectedIDs.contains($0.id)
                && (sessionIDs?.contains($0.id) ?? true)}).sorted(by:{$0.pid<$1.pid}) {
                let id=original.id,explicit=codexAttachmentToolHostGrants[home]?[original.id] != nil,approvedToolHosts=codexAttachmentToolHostGrants[home]?[original.id] ?? []
                guard authorized(id) else{return}
                guard codexSessionAttachments[id]==nil else{continue}
                guard let host=ScreenHost(kind:original.terminal),[ScreenHost.terminal,.iterm,.pty].contains(host),screenConnections[host]?.enabled == true,
                      screenAdapters[host]?.restart != nil else{wait(original,"Terminal·iTerm 화면 연결 필요 · Mac 연결 설정에서 연결해주세요");continue}
                var selectedIdle=false
                if sessionIDs?.contains(id)==true,original.phase == .unknown,let adapter=screenAdapters[host] {
                    let target=ScreenTarget(tty:original.tty,handle:original.screenHandle,jobPIDs:[original.pid],sourcePID:original.pid,sourceStarted:original.started)
                    let observed=try await Task.detached(priority:.utility){try adapter.readForValidation([target])}.value
                    selectedIdle=observed.failures.isEmpty && observed.screens.count==1 && observed.screens.first.map{CodexGoalScreen.ready($0.contents)}==true
                }
                guard (original.phase == .idle || selectedIdle || explicit && (original.phase == .working || original.phase == .unknown)),!original.pendingInTerminal,!original.needsReview else {
                    let reason=original.phase == .working ? "작업 실행 중 · 완료 후 자동 연결":original.phase == .unknown ? "터미널 입력 대기 화면 확인 중":original.phase == .input ? "작성 중인 입력·질문 유지":"승인·질문 응답 대기"
                    wait(original,reason);continue
                }
                guard let process=live.first(where:{$0.key==id && $0.agent == .codex && "/dev/"+$0.tty==original.tty}),process.isForeground,
                      let executable=CodexServerLocation.executable(process) else {wait(original,"원본 실행 정보 확인 필요");continue}
                let parents=ProcessDiscovery.ancestors(of:process.parent,byPID:ProcessDiscovery.index(live))
                let originalShell=parents.first(where:{$0.tty==process.tty && SessionExitRecovery.isShell($0)})
                let login=originalShell==nil ? parents.first(where:{$0.pid==process.parent && $0.tty==process.tty && ($0.executable as NSString).lastPathComponent=="login"}):nil
                guard let shell=originalShell ?? login else{wait(original,"원본 셸·직접 실행 login 확인 필요");continue}
                if login != nil,host != .terminal || screenAdapters[host]?.replacementShell==nil || screenAdapters[host]?.replacementShellValid==nil {wait(original,"셸 없는 실행 · 같은 창의 복구 탭 준비 필요");continue}
                let location=try? await Task.detached(priority:.utility){try CodexThreadLocation.locate(paths:ProcessOpenFiles.codexRolloutPaths(pid:process.pid,expectedStart:process.started))}.value
                var threadID:String?
                if let location,try CodexAccountTransitionTarget.canonicalHome(URL(fileURLWithPath:location.database).deletingLastPathComponent().path)==home {threadID=location.threadID}
                else {
                    guard let selected=try? await CodexReplyTransport.selectedQueueTarget(original),selected.home==home else{wait(original,"실행 중인 Codex의 설정 홈 확인 필요");continue}
                    guard (explicit && original.phase == .working || !CodexSessionAttachment.hasIndependentChildWork(process:process,records:live,authorizedToolHosts:approvedToolHosts)),let adapter=screenAdapters[host] else{wait(original,"하위 작업 완료 대기");continue}
                    codexAttachmentActiveIDs.insert(id)
                    threadID=try await identifyStandaloneCodex(original,home:home,adapter:adapter,allowWorking:explicit,authorized:{authorized(id)})
                    codexAttachmentActiveIDs.remove(id)
                }
                guard authorized(id),let threadID else{wait(original,"현재 대화의 상태 카드 확인 대기");continue}
                let goal=try await Task.detached(priority:.utility){try CodexSessionAttachment.goalIfPresent(home:home,threadID:threadID)}.value
                guard goal?.status != .active || explicit else {wait(original,"활성 Goal · 완료 후 자동 연결");continue}
                guard original.phase == .idle || selectedIdle || goal?.status == .active || explicit && goal?.status == .paused else{wait(original,"실행 중 작업 유지 · Goal 확인 필요");continue}
                var context=SessionExitRecovery(session:original,process:process,shell:shell,conversationID:threadID)
                context.executable=executable
                context.codexLaunch=try await Task.detached(priority:.utility){try CodexSessionLaunch.capture(process)}.value
                var attachment=CodexSessionAttachment(context:context,home:home,originalLogin:login,authorizedToolHosts:approvedToolHosts)
                if goal?.status == .paused {attachment.pausedGoal=goal}
                if goal?.status == .active {attachment.goalBeforePause=goal;attachment.phase = .needsPause}
                try saveCodexSessionAttachment(attachment)
            }
            for savedState in codexSessionAttachments.values.filter({$0.home==home && ![.connected,.review].contains($0.phase)
                && (sessionIDs?.contains($0.context.session.id) ?? true)}).sorted(by:{$0.context.session.pid<$1.context.session.pid}) {
                var updatedState=savedState
                if updatedState.context.codexLaunch==nil,![.launchReserved,.verifying].contains(updatedState.phase) {
                    let savedContext=updatedState.context
                    updatedState.context.codexLaunch=try await Task.detached(priority:.utility) {
                        try CodexSessionLaunch.forAttachment(savedContext,home:home,records:reader())
                    }.value
                    try saveCodexSessionAttachment(updatedState)
                }
                let state=updatedState
                let context=state.context,original=context.session,id=original.id
                if state.phase == .needsPause,codexAttachmentToolHostGrants[home]?[id]==nil {wait(original,"Goal 일시정지·재연결 직접 요청 대기");continue}
                guard authorized(id),let host=ScreenHost(kind:original.terminal),screenConnections[host]?.enabled==true,let adapter=screenAdapters[host],let restart=adapter.restart else{return}
                let resolveRuntime=codexAttachmentRuntime
                let preflight:[CodexSessionAttachment.Phase] = [.needsPause,.needsTab,.ready]
                if preflight.contains(state.phase) {
                    guard let launchIdentity=context.codexLaunch else{throw AppError.message("원래 Codex 실행 환경을 확인하지 못했습니다.")}
                    _ = try await resolveRuntime(launchIdentity,home,.server)
                }
                codexAttachmentActiveIDs.insert(id)
                let frozenIdentity=state.phase == .needsPause && host == .terminal ? try? TTYInputIdentity.capture(pid:original.pid):nil
                let target=ScreenTarget(tty:original.tty,handle:original.screenHandle,jobPIDs:[original.pid],sourcePID:original.pid,sourceStarted:original.started,sourceIdentity:frozenIdentity)
                func cleanupFinished(_ records:[ProcessRecord])->Bool {
                    let witnesses=state.toolHostShutdownWitnesses ?? state.authorizedToolHosts ?? []
                    return !witnesses.contains {host in records.contains(where:{$0.key==host.key})}
                }
                func screen(_ target:ScreenTarget) async throws->String {
                    guard authorized(id) else{throw CancellationError()}
                    let result=try await Task.detached(priority:.utility){try adapter.readForValidation([target])}.value
                    guard authorized(id),result.failures.isEmpty,result.screens.count==1,let raw=result.screens.first?.contents else{throw AppError.message("원본 터미널 화면을 확인하지 못했습니다.")}
                    return raw
                }
                if state.phase == .ready || state.phase == .needsTab {
                    let raw=try await screen(target)
                    if state.pausedGoal != nil,CodexGoalScreen.ready(raw) {self.receiveScreen(sessionID:id,raw:raw,generation:"goal-attachment-pause",source:.terminalScreen)}
                    let current=try await Task.detached(priority:.utility){try reader()}.value
                    guard (sessions[id]?.phase == .idle || state.pausedGoal != nil || sessionIDs?.contains(id)==true && sessions[id]?.phase == .unknown),sessions[id]?.needsReview == false,
                          let process=current.first(where:{$0.key==id}),!CodexSessionAttachment.hasIndependentChildWork(process:process,records:current,authorizedToolHosts:state.authorizedToolHosts ?? []),
                          CodexGoalScreen.ready(raw) else {
                        codexSessionAttachmentNotice="기존 작업·질문·초안·하위 작업이 끝날 때까지 같은 창에서 연결을 기다립니다."
                        codexAttachmentActiveIDs.remove(id);continue
                    }
                }
                let services=CodexSessionAttachmentServices(exit:{
                    let current=try await Task.detached(priority:.utility){try reader()}.value
                    guard authorized(id),let process=current.first(where:{$0.key==id && "/dev/"+$0.tty==original.tty && $0.isForeground}),
                          current.contains(where:{$0.key==context.shell.key}),(self.sessions[id]?.phase == .idle || state.pausedGoal != nil || sessionIDs?.contains(id)==true && self.sessions[id]?.phase == .unknown),self.sessions[id]?.needsReview == false,
                          CodexServerLocation.executable(process)==context.executable,
                          CodexServerLocation.connectedHome(pid:process.pid,hints:[home])==nil else{throw AppError.message("원래 실행이나 입력 상태가 바뀌어 종료하지 않았습니다.")}
                    guard !CodexSessionAttachment.hasIndependentChildWork(process:process,records:current,authorizedToolHosts:state.authorizedToolHosts ?? []) else{throw AppError.message("분리된 하위 작업이 있어 자동 연결을 보류했습니다.")}
                    if let login=state.originalLogin {
                        guard process.parent==login.pid,current.contains(where:{$0==login}),SessionExitRecovery.foregroundShell(in:current,tty:context.shell.tty)?.key==context.shell.key,
                              let validate=adapter.replacementShellValid else{throw AppError.message("복구 셸이나 원래 login 실행이 바뀌었습니다.")}
                        let sameWindow=try await Task.detached(priority:.utility){try validate(target,context.shell)}.value
                        guard sameWindow else{throw AppError.message("복구 탭이 원래 창과 같은 창이 아닙니다.")}
                        let replacementTarget=ScreenTarget(tty:"/dev/"+context.shell.tty,jobPIDs:[context.shell.pid],sourcePID:context.shell.pid,sourceStarted:context.shell.started)
                        guard context.shell.isForeground,SessionExitRecovery.emptyShellPrompt(try await screen(replacementTarget)) else{throw AppError.message("복구 탭에 다른 작업·입력이 있어 원래 Codex를 종료하지 않았습니다.")}
                    }
                    let files=try ProcessOpenFiles.codexRolloutPaths(pid:process.pid,expectedStart:process.started)
                    if state.replacesTab || state.pausedGoal != nil,files.isEmpty {
                        let identified=try await self.identifyStandaloneCodex(original,home:home,adapter:adapter,authorized:{authorized(id)})
                        guard identified==context.conversationID else{throw AppError.message("탭 준비 뒤 원래 대화가 바뀌었습니다.")}
                    }
                    let before=try await screen(target)
                    if let location=try? CodexThreadLocation.locate(paths:files) {
                        guard location.threadID==context.conversationID else{throw AppError.message("원래 대화가 바뀌었습니다.")}
                    } else {
                        guard let thread=context.conversationID,let saved=self.store.value("codexStatusIdentity:"+id),let data=saved.data(using:.utf8),
                              let proof=try? JSONDecoder().decode(CodexStatusIdentity.self,from:data),proof.matches(before,thread:thread),
                              try await CodexReplyTransport.selectedQueueTarget(original).home==home else{throw AppError.message("현재 대화 상태가 바뀌어 종료하지 않았습니다.")}
                        let matches=try await Task.detached(priority:.utility){
                            let result=try CodexQueueConnection(home:home).request("thread/read",["threadId":thread,"includeTurns":false])
                            guard let row=result["thread"] as? JSONObject else{return false}
                            return row["id"] as? String==thread && (row["cwd"] as? String).map{URL(fileURLWithPath:$0).resolvingSymlinksInPath().path}==URL(fileURLWithPath:original.cwd).resolvingSymlinksInPath().path
                                && (row["parentThreadId"] == nil || row["parentThreadId"] is NSNull)
                                && row["ephemeral"] as? Bool==false && row["source"] is String
                                && (row["source"] as? String=="cli" || row["threadSource"] as? String=="user")
                        }.value
                        guard matches else{throw AppError.message("원래 대화와 서버의 기록이 일치하지 않습니다.")}
                    }
                    guard CodexGoalScreen.ready(before) else{throw AppError.message("작업·질문·초안이 끝난 빈 입력창을 기다립니다.")}
                    try await Task.sleep(for:.milliseconds(350))
                    guard try await screen(target)==before else{throw AppError.message("사람 입력이나 화면 변경으로 자동 연결을 보류했습니다.")}
                    guard let thread=context.conversationID else{throw AppError.message("원래 대화 ID를 확인하지 못했습니다.")}
                    let goal=try await Task.detached(priority:.utility){try CodexSessionAttachment.goalIfPresent(home:home,threadID:thread)}.value
                    guard goal?.status != .active,state.pausedGoal==nil || goal?.revision==state.pausedGoal?.revision else{throw AppError.message("Goal 상태가 바뀌어 자동 연결을 보류했습니다.")}
                    _ = try await Task.detached(priority:.utility){try CodexQueueConnection(home:home).peerProcessID()}.value
                    guard try await screen(target)==before else{throw AppError.message("서버 확인 중 화면이 바뀌어 종료하지 않았습니다.")}
                    guard self.log(AuditEvent(sessionID:id,summary:"기존 Codex 서버 연결",outcome:state.authorizedToolHosts?.isEmpty == false ? "사용자 재연결 요청 · 확인한 도구 호스트 정리를 포함한 정상 종료 예약":"같은 창·대화 연결을 위한 종료 요청 예약",source:host.title,context:AuditContext(session:original))) else{throw AppError.message("연결 기록을 저장하지 못했습니다.")}
                    return try await Task.detached(priority:.utility){try adapter.input(target,before,.codex,.init(kind:.message,text:"/exit")) == .sent}.value
                },shellReady:{
                    let current=try await Task.detached(priority:.utility){try reader()}.value
                    guard authorized(id),cleanupFinished(current),let shell=context.verifiedShell(in:current) else{return false}
                    let source=ScreenTarget(tty:"/dev/"+shell.tty,handle:state.replacesTab ? nil:original.screenHandle,jobPIDs:[shell.pid],sourcePID:shell.pid,sourceStarted:shell.started)
                    return SessionExitRecovery.emptyShellPrompt(try await screen(source))
                },launch:{
                    guard let launchIdentity=context.codexLaunch else{throw AppError.message("원래 Codex 실행 환경을 확인하지 못했습니다.")}
                    let cli=try await resolveRuntime(launchIdentity,home,.server)
                    let command=try state.command(using:cli)
                    let current=try await Task.detached(priority:.utility){try reader()}.value
                    guard authorized(id),cleanupFinished(current),let shell=context.verifiedShell(in:current) else{throw AppError.message("원래 셸·실행 파일·대화를 확인하지 못했습니다.")}
                    let source=ScreenTarget(tty:"/dev/"+shell.tty,handle:state.replacesTab ? nil:original.screenHandle,jobPIDs:[shell.pid],sourcePID:shell.pid,sourceStarted:shell.started)
                    let before=try await screen(source)
                    guard SessionExitRecovery.emptyShellPrompt(before) else{throw AppError.message("셸 입력창이 비어 있지 않습니다.")}
                    try cli.verifyUnchanged()
                    return try await Task.detached(priority:.utility){try restart(source,before,command) == .sent}.value
                },verify:{
                    let current=try await Task.detached(priority:.utility){try reader()}.value
                    let candidates=current.filter{$0.agent == .codex && $0.tty==context.shell.tty && $0.key != id && ProcessDiscovery.ancestors(of:$0.parent,byPID:ProcessDiscovery.index(current)).contains(where:{$0.key==context.shell.key})}
                    guard authorized(id),cleanupFinished(current),candidates.count==1,let next=candidates.first,CodexServerLocation.connectedHome(pid:next.pid,hints:[home])==home,let thread=context.conversationID else{return false}
                    let loaded=try await Task.detached(priority:.utility){
                        let result=try CodexQueueConnection(home:home).request("thread/read",["threadId":thread,"includeTurns":false])
                        guard let row=result["thread"] as? JSONObject else{return false}
                        return row["id"] as? String==thread && CodexQueueTransport.isLoadedRoot(row,cwd:original.cwd)
                    }.value
                    guard loaded else{return false}
                    self.sessions[next.key]?.automatic=original.automatic
                    try self.store.set("automatic:"+next.key,original.automatic ? "true":"false")
                    return true
                },prepareReplacement:{
                    guard authorized(id),let prepare=adapter.replacementShell else{throw AppError.message("원래 창의 복구 탭 준비를 지원하지 않습니다.")}
                    let current=try await Task.detached(priority:.utility){try reader()}.value
                    guard let process=current.first(where:{$0.key==id && $0.isForeground}),!CodexSessionAttachment.hasIndependentChildWork(process:process,records:current,authorizedToolHosts:state.authorizedToolHosts ?? []),
                          CodexGoalScreen.ready(try await screen(target)) else{throw AppError.message("원래 작업·질문·입력이 끝나기를 기다립니다.")}
                    return try await Task.detached(priority:.utility){try prepare(target)}.value
                },pause:{
                    guard authorized(id),self.codexAttachmentToolHostGrants[home]?[id] != nil,let expected=state.goalBeforePause,let thread=context.conversationID else{throw CancellationError()}
                    let current=try await Task.detached(priority:.utility){try reader()}.value
                    guard current.contains(where:{$0.key==id && $0.isForeground && "/dev/"+$0.tty==original.tty}),try await CodexReplyTransport.selectedQueueTarget(original).home==home else{throw AppError.message("원본 실행·홈·하위 작업이 바뀌어 Goal을 중단하지 않았습니다.")}
                    guard try CodexSessionAttachment.goalIfPresent(home:home,threadID:thread)?.revision==expected.revision else{throw AppError.message("원래 Goal이 바뀌어 중단하지 않았습니다.")}
                    let before=try await screen(target),working=CodexGoalScreen.workingReady(before)
                    let files=try ProcessOpenFiles.codexRolloutPaths(pid:original.pid,expectedStart:original.started)
                    if let location=try? CodexThreadLocation.locate(paths:files) {
                        guard location.threadID==thread else{throw AppError.message("원래 대화가 바뀌어 Goal을 중단하지 않았습니다.")}
                    } else {
                        guard let saved=self.store.value("codexStatusIdentity:"+id),let data=saved.data(using:.utf8),let proof=try? JSONDecoder().decode(CodexStatusIdentity.self,from:data),proof.threadID==thread,
                              proof.matches(before,thread:thread) || working && Date().timeIntervalSince(proof.requested)<120 && proof.freshThread(in:before)==thread else{throw AppError.message("Goal 중단 전 대화 화면이 바뀌었습니다.")}
                    }
                    if working,host == .terminal {
                        guard target.sourceIdentity != nil,adapter.goalInterrupt != nil || self.terminalInputAvailable() else{throw RemoteHTTPError(409,"Mac 연결 설정의 직접 입력 연결과 원본 Codex 신원을 확인해주세요.",diagnostics:["delivery":"not_started"])}
                    }
                    guard working || CodexGoalScreen.ready(before),!RemoteMessageReadiness.hasMenu(before,agent:.codex),CodexProgressScreen.emptyComposer(before) else{throw AppError.message("질문·초안·입력을 유지하고 Goal 중단을 보류했습니다.")}
                    guard self.log(AuditEvent(sessionID:id,summary:"기존 Codex Goal 서버 연결",outcome:"사용자 재연결 요청 · 원래 Goal 일시정지·중단 예약",source:host.title,context:AuditContext(session:original))) else{throw AppError.message("Goal 중단 기록을 저장하지 못했습니다.")}
                    return try await Task.detached(priority:.utility){
                        if working,let interrupt=adapter.goalInterrupt {return try interrupt(target,before) == .sent}
                        return try adapter.input(target,before,.codex,.init(kind:working ? .escape:.submit,text:working ? "":"/goal pause")) == .sent
                    }.value
                },pauseReady:{
                    guard authorized(id),let before=state.goalBeforePause,let thread=context.conversationID else{throw CancellationError()}
                    let current=try await Task.detached(priority:.utility){try reader()}.value
                    guard current.contains(where:{$0.key==id && $0.isForeground}),let goal=try CodexSessionAttachment.goalIfPresent(home:home,threadID:thread),goal.status == .paused,goal.instanceID==before.instanceID,goal.createdAt==before.createdAt,goal.objective==before.objective,goal.tokenBudget==before.tokenBudget else{return nil}
                    let raw=try await screen(target)
                    guard CodexGoalScreen.ready(raw) else{return nil}
                    self.receiveScreen(sessionID:id,raw:raw,generation:"goal-attachment-pause",source:.terminalScreen)
                    return goal
                })
                _ = try await services.advance(state,save:{try self.saveCodexSessionAttachment($0)})
                codexAttachmentActiveIDs.remove(id)
                if codexSessionAttachments[id]?.phase != .connected {break}
                if var connected=self.codexSessionAttachments[id],let goal=connected.goalBeforePause {
                    let rows=try await Task.detached(priority:.utility){try reader()}.value
                    let targets=try await self.codexAccountTargetReader(rows)
                    guard let target=targets.first(where:{$0.home==home}) else{throw AppError.message("Goal 연결 뒤 서버 확인을 기다립니다.")}
                    let observed=try await self.codexAccountTransitionServices.observe(target)
                    guard var stopped=observed.threads.first(where:{$0.id==context.conversationID}),!stopped.active,stopped.blocker==nil,stopped.goal?.revision==connected.pausedGoal?.revision else{throw AppError.message("연결 뒤 원래 Goal·실행 차례를 확인하지 못했습니다. Goal은 일시정지로 유지합니다.")}
                    stopped.goal=goal;connected.stoppedThread=stopped;try self.saveCodexSessionAttachment(connected)
                }
                live=try await Task.detached(priority:.utility){try reader()}.value
            }
            // This notice is global: a later healthy home must not erase
            // another home's still-live blocker. Preserve the journal itself.
            let review=RemoteDiagnostics.currentReviews(Array(codexSessionAttachments.values),records:live).sorted{$0.context.session.pid<$1.context.session.pid}
            let progress=codexSessionAttachments.values.filter{$0.phase != .review && $0.phase != .connected && RemoteDiagnostics.isCurrent($0,records:live)}.sorted{$0.context.session.pid<$1.context.session.pid}
            let pending=codexAttachmentWaitReasons.filter{key,_ in live.contains(where:{$0.key==key}) && !connectedIDs.contains(key)}.sorted{$0.key<$1.key}
            if let first=review.first {codexSessionAttachmentNotice="기존 세션 \(review.count)개 확인 필요 · PID \(first.context.session.pid): "+first.detail}
            else if let first=progress.first {codexSessionAttachmentNotice="기존 세션 \(progress.count)개 연결 중 · PID \(first.context.session.pid): "+first.detail}
            else if !pending.isEmpty {
                let details=pending.map {id,reason in
                    guard let session=snapshot.sessions.first(where:{$0.id==id}) else{return "• "+reason}
                    return "• "+session.project+" · "+session.tty.replacingOccurrences(of:"/dev/",with:"")+": "+reason
                }
                codexSessionAttachmentNotice="기존 세션 \(pending.count)개 연결 대기\n"+details.joined(separator:"\n")
            } else {codexSessionAttachmentNotice=nil}
        } catch {codexSessionAttachmentNotice="기존 세션 자동 연결 보류: "+String(error.localizedDescription.prefix(240))}
    }
    /// Returns a bounded, allowlisted diagnostic report. Collection never starts
    /// a daemon, sends terminal input, reads auth files or changes a Goal.
    public func diagnostics(nodeID:String?=nil,name:String?=nil) async -> JSONObject {
        let sessionCopy=snapshot.sessions,journal=Array(codexSessionAttachments.values),transitions=codexAccountTransitionStates,eventCopy=snapshot.events
        let reader=processReader,targetReader=codexAccountTargetReader,services=codexManagedServerServices
        var failures:[String]=[],rows:[ProcessRecord]?,targets:[CodexAccountTransitionTarget]?
        do {rows=try await Task.detached(priority:.utility){try reader()}.value}
        catch {failures.append("프로세스 목록을 읽지 못했습니다. 원본 실행은 확인 불가로 표시합니다.")}
        if let rows {
            do {targets=try await targetReader(rows)}
            catch {failures.append("관리형 서버의 실제 세션 연결 증거를 읽지 못했습니다.")}
        }
        var homes=Set((targets ?? []).map(\.home))
        if let home=try? CodexAccountTransitionTarget.canonicalHome(NSHomeDirectory()+"/.codex"){homes.insert(home)}
        for row in (rows ?? []).filter({$0.agent == .codex}) {
            if let raw=diagnosticEnvironment(row)?["CODEX_HOME"],let home=try? CodexAccountTransitionTarget.canonicalHome(raw){homes.insert(home)}
        }
        for state in journal.prefix(8) {homes.insert(state.home)}
        var statuses:[String:CodexManagedServerStatus]=[:]
        let selected=Array(homes.sorted().prefix(8)),records=rows ?? []
        await withTaskGroup(of:(String,CodexManagedServerStatus).self) {group in
            for home in selected {group.addTask {
                let state=await withTaskGroup(of:CodexManagedServerStatus.self) {race in
                    race.addTask {do{return try await services.inspect(home,records)}catch{return .init(phase:.unavailable,detail:"서버 상태 조회를 완료하지 못했습니다.")}}
                    race.addTask {try? await Task.sleep(for:.seconds(6));return .init(phase:.unavailable,detail:"서버 상태 조회 시간이 지났습니다. 세션은 변경하지 않았습니다.")}
                    let first=await race.next()!;race.cancelAll();return first
                }
                return (home,state)
            }}
            for await (home,status) in group {statuses[home]=status}
        }
        if homes.count>8 {failures.append("설정 홈이 많아 처음 8개만 조회했습니다.")}
        let keyboard=TerminalKeyboard.isAvailable,posting=CGPreflightPostEventAccess(),direct=terminalInputAvailable()
        let permissions:[JSONObject]=[
            ["id":"accessibility","label":"손쉬운 사용","state":keyboard ? "ok":"attention","detail":keyboard ? "이 앱의 권한이 허용되어 있습니다.":"원래 창을 검증하는 키보드 입력에는 이 Mac의 승인이 필요합니다."],
            ["id":"event_posting","label":"키 입력 권한","state":posting ? "ok":"attention","detail":posting ? "키 이벤트 게시가 허용되어 있습니다.":"이 앱의 키 이벤트 게시 허용을 확인해주세요."],
            ["id":"direct_input","label":"Terminal 직접 입력","state":direct ? "ok":"unavailable","detail":direct ? "손쉬운 사용 권한으로 원본 터미널에 입력합니다.":"Mac의 손쉬운 사용에서 AutoApprove를 허용해주세요. 별도 입력 서비스를 설치하지 않습니다."]]
        var report = RemoteDiagnostics.report(nodeID:nodeID ?? store.value("webNodeID") ?? "local",name:name ?? Host.current().localizedName ?? "Mac",sessions:sessionCopy,records:rows,targets:targets,servers:statuses,attachments:journal,transitions:transitions,events:eventCopy,permissions:permissions,errors:failures)
        if let delivery = groupDeliveryCheck() {
            report["checks"] = ((report["checks"] as? [JSONObject]) ?? []) + [delivery]
            if delivery["state"] as? String == "attention", var summary = report["summary"] as? JSONObject, summary["level"] as? String == "ok" {
                summary["level"] = "attention"; report["summary"] = summary
            }
        }
        return report
    }

    /// Session-group delivery for every agent, Claude included: a member whose first queued message
    /// could not be typed, or that holds a parked message, is reported with the last hold reason.
    private func groupDeliveryCheck() -> JSONObject? {
        guard let groups = try? SessionGroupStore(directory: paths.directory).load(), !groups.isEmpty,
              let box = try? groupMailbox() else { return nil }
        var held: [String] = [], pending = 0
        for group in groups {
            guard let inboxes = try? box.inboxOperations(groupID: group.id) else { continue }
            for member in group.members {
                guard let inbox = inboxes[member.id] else { continue }
                pending += inbox.unacknowledgedCount
                guard inbox.unacknowledgedCount > 0, inbox.headDidNotStart || inbox.hasParkedMessage else { continue }
                let since = inbox.firstPendingAt.map { " · 가장 오래된 메시지 " + $0.formatted(date: .omitted, time: .shortened) } ?? ""
                // Names are left out: a diagnostic snapshot may be handed to an analysis model.
                let role = group.isLeader(member.id) ? "그룹장" : "구성원"
                held.append("\(role) \(member.id.uuidString.prefix(8)): 미전달 \(inbox.unacknowledgedCount)건\(since) · \(inbox.lastDeliveryFailure ?? "사유 미기록")")
            }
        }
        let detail = held.isEmpty ? "그룹 \(groups.count)개 · 수신 미확인 \(pending)건 · 전달이 막힌 구성원 없음"
            : "전달이 막힌 구성원 \(held.count)명 · " + held.prefix(6).joined(separator: " / ") + (held.count > 6 ? " 외 \(held.count - 6)명" : "")
        return ["id": "group_delivery", "label": "세션 그룹 메시지 전달", "state": held.isEmpty ? "ok" : "attention", "detail": detail]
    }
    public func diagnosticCodexAction(_ object:JSONObject,nodeID:String,name:String) async throws -> JSONObject {
        guard let action=object["action"] as? String,let request=object["requestID"] as? String,UUID(uuidString:request) != nil else{throw RemoteHTTPError(400,"진단 요청 ID를 확인해주세요.")}
        if action=="cancel" {
            if codexDiagnostics.status(requestID:request) != nil {return try diagnosticJobObject(codexDiagnostics.cancel(requestID:request))}
            guard var preparation=diagnosticPreparations[request] else{throw RemoteHTTPError(404,"진단 요청을 찾을 수 없습니다.")}
            if preparation.phase=="running" {
                preparation.phase="cancelled";preparation.message="진단 자료 수집을 취소했습니다.";preparation.updatedAt=ISO8601DateFormatter().string(from:Date());diagnosticPreparations[request]=preparation
                if diagnosticCollectingRequest==request {diagnosticPreparationTask?.cancel()}
            }
            return try diagnosticJobObject(preparation)
        }
        guard action=="start",!remoteInputStopped else{throw RemoteHTTPError(400,"지원하지 않는 진단 요청입니다.")}
        guard !agentAccounts.busy else{throw RemoteHTTPError(409,"이 Mac의 로그인이 끝난 뒤 진단을 시작해주세요.",diagnostics:["delivery":"not_started"])}
        let question=object["question"] as? String ?? "",serverID=object["serverID"] as? String ?? ""
        guard question.count<=2000,serverID.count<=64 else{throw RemoteHTTPError(400,"진단 질문은 2,000자 이내로 입력해주세요.")}
        let intent=String(decoding:try JSONSerialization.data(withJSONObject:["question":question,"serverID":serverID],options:.sortedKeys),as:UTF8.self)
        if let previous=diagnosticRequestIntents[request] {
            guard previous==intent else{throw RemoteHTTPError(409,"같은 진단 ID의 요청 내용이 다릅니다.")}
            return try diagnosticCodexStatus(requestID:request)
        }
        guard !codexDiagnostics.busy,diagnosticCollectingRequest==nil else{throw RemoteHTTPError(409,"이 Mac의 다른 진단이 끝난 뒤 시작해주세요.")}
        guard diagnosticRequestIntents.count<256 else{throw RemoteHTTPError(429,"진단 요청 한도에 도달했습니다. 앱을 다시 시작해주세요.")}
        let stamp=ISO8601DateFormatter().string(from:Date())
        let preparation=CodexDiagnosticJob(id:request,phase:"running",startedAt:stamp,updatedAt:stamp,message:"이 Mac의 진단 자료를 수집 중입니다.",result:nil)
        diagnosticRequestIntents[request]=intent;diagnosticPreparations[request]=preparation;latestDiagnosticRequestID=request;diagnosticCollectingRequest=request
        // Reservation is immediately observable. Losing the HTTP reply cannot
        // hide preparation or silently create a second diagnostic child.
        diagnosticPreparationTask=Task { @MainActor [weak self] in
            guard let self else{return}
            defer{if self.diagnosticCollectingRequest==request {self.diagnosticCollectingRequest=nil;self.diagnosticPreparationTask=nil}}
            do {
                let report=await self.diagnostics(nodeID:nodeID,name:name)
                guard !Task.isCancelled,!self.remoteInputStopped,self.diagnosticPreparations[request]?.phase=="running" else{return}
                let reader=self.processReader,records=try await Task.detached(priority:.utility){try reader()}.value
                var allowed=Set<String>()
                for target in (try? await self.codexAccountTargetReader(records)) ?? [] {allowed.insert(target.home)}
                if let home=try? CodexAccountTransitionTarget.canonicalHome(NSHomeDirectory()+"/.codex"){allowed.insert(home)}
                for row in records where row.agent == .codex {
                    if let value=diagnosticEnvironment(row)?["CODEX_HOME"],let home=try? CodexAccountTransitionTarget.canonicalHome(value){allowed.insert(home)}
                }
                let home:String
                if serverID.isEmpty {home=try CodexAccountTransitionTarget.canonicalHome(NSHomeDirectory()+"/.codex")}
                else {guard let matched=allowed.first(where:{RemoteDiagnostics.homeID($0)==serverID}) else{throw RemoteHTTPError(409,"진단 대상 홈이 바뀌었습니다.")};home=matched}
                let executable=records.filter{$0.agent == .codex}.first(where:{(self.diagnosticEnvironment($0)?["CODEX_HOME"] ?? NSHomeDirectory()+"/.codex")==home}).flatMap{CodexServerLocation.executable($0)}
                let data=try JSONSerialization.data(withJSONObject:report,options:.sortedKeys)
                guard !Task.isCancelled,self.diagnosticPreparations[request]?.phase=="running" else{return}
                _ = try self.codexDiagnostics.start(requestID:request,home:home,executable:executable,snapshot:data,question:RemoteDiagnostics.text(question,limit:2000))
            } catch {
                guard var failed=self.diagnosticPreparations[request],failed.phase=="running" else{return}
                failed.phase=Task.isCancelled ? "cancelled":"failed";failed.updatedAt=ISO8601DateFormatter().string(from:Date());failed.message=Task.isCancelled ? "진단 준비를 취소했습니다.":"진단 준비를 완료하지 못했습니다. 상태와 로그인 홈을 새로 확인해주세요.";self.diagnosticPreparations[request]=failed
            }
        }
        return try diagnosticJobObject(preparation)
    }
    private func diagnosticJobObject(_ job:CodexDiagnosticJob?) throws -> JSONObject {
        guard let job else{return ["job":NSNull()]}
        return ["job":try JSONSerialization.jsonObject(with:JSONEncoder().encode(job))]
    }
    public func diagnosticCodexStatus(requestID:String?=nil)throws->JSONObject {
        if let requestID,UUID(uuidString:requestID)==nil {throw RemoteHTTPError(400,"진단 요청 ID가 올바르지 않습니다.")}
        let request=requestID ?? latestDiagnosticRequestID
        return try diagnosticJobObject(codexDiagnostics.status(requestID:request) ?? request.flatMap{diagnosticPreparations[$0]})
    }

    public func codexManagedServerStatus(home:String) async throws ->CodexManagedServerStatus {
        try validateCodexLoginHome(home)
        let reader=processReader
        let records=try await Task.detached(priority:.utility){try reader()}.value
        try Task.checkCancellation()
        let result=try await codexManagedServerServices.inspect(home,records)
        try validateCodexLoginHome(home)
        return result
    }
    public func prepareCodexManagedServer(home:String) async throws ->CodexManagedServerStatus {
        try validateCodexLoginHome(home)
        let selectedHome=home
        guard !remoteInputStopped,!codexAccountTransitionBusy,!codexAccountTransitionHeld,!agentAccounts.busy else {
            throw AppError.message(codexAccountControlBlockReason() ?? "현재 연결 상태를 확인해주세요.")
        }
        let epoch=codexAccountTransitionEpoch,reader=processReader
        codexAccountTransitionBusy=true
        defer {if epoch==codexAccountTransitionEpoch {codexAccountTransitionBusy=false;codexManagedServerStartTask=nil}}
        let home=try CodexAccountTransitionTarget.canonicalHome(home)
        let records=try await Task.detached(priority:.utility){try reader()}.value
        try Task.checkCancellation()
        guard epoch==codexAccountTransitionEpoch,!remoteInputStopped else{throw CancellationError()}
        try validateCodexLoginHome(selectedHome)
        guard try CodexAccountTransitionTarget.canonicalHome(selectedHome)==home else{throw AppError.message("준비할 로그인 그룹의 홈이 바뀌었습니다.")}
        let services=codexManagedServerServices
        let task=Task {try await services.prepare(home,records)}
        codexManagedServerStartTask=task
        let result=try await withTaskCancellationHandler(operation:{try await task.value},onCancel:{task.cancel()})
        guard epoch==codexAccountTransitionEpoch,!remoteInputStopped else{throw CancellationError()}
        try validateCodexLoginHome(selectedHome)
        if result.phase == .running {codexAttachmentHomes.insert(home)}
        return result
    }
    /// Explicitly observational; never calls the account-transition coordinator.
    public func inspectCodexAccount(home:String) async throws ->CodexAccountInspection {
        try Task.checkCancellation()
        guard !remoteInputStopped else{throw CancellationError()}
        let selectedHome=home
        try validateCodexLoginHome(selectedHome)
        let home=try CodexAccountTransitionTarget.canonicalHome(home)
        let scopeEpoch=codexAccountTransitionEpoch
        let readEpoch=codexAccountInspectionEpochs[home] ?? UUID()
        codexAccountInspectionEpochs[home]=readEpoch
        let entry:(id:UUID,task:Task<CodexAccountInspection,Error>)
        if let pending=codexAccountInspectionTasks[home] {entry=pending}
        else {
            let epoch=codexAccountTransitionEpoch
            entry=(UUID(),Task { @MainActor [weak self] in
                guard let self else{throw CancellationError()}
                return try await self.performCodexAccountInspection(home:home,epoch:epoch)
            })
            codexAccountInspectionTasks[home]=entry
        }
        defer {if codexAccountInspectionTasks[home]?.id==entry.id {codexAccountInspectionTasks.removeValue(forKey:home)}}
        let result=try await entry.task.value
        try Task.checkCancellation()
        guard scopeEpoch==codexAccountTransitionEpoch,codexAccountInspectionEpochs[home]==readEpoch,!remoteInputStopped else{throw CancellationError()}
        try validateCodexLoginHome(selectedHome)
        return result
    }
    private func invalidateCodexAccountInspection(home:String) {
        codexAccountInspectionEpochs[home]=UUID()
        codexAccountInspectionTasks.removeValue(forKey:home)?.task.cancel()
    }
    private func performCodexAccountInspection(home:String,epoch:UUID) async throws ->CodexAccountInspection {
        try validateCodexLoginHome(home)
        let reader=processReader,targetReader=codexAccountTargetReader
        let rows=try await Task.detached(priority:.utility){try reader()}.value
        try Task.checkCancellation()
        let targets=try await targetReader(rows)
        let known=Set(rows.filter{$0.agent == .codex}.compactMap{diagnosticEnvironment($0)?["CODEX_HOME"].flatMap{try? CodexAccountTransitionTarget.canonicalHome($0)}})
        let target:CodexAccountTransitionTarget
        if let current=targets.first(where:{$0.home==home}) {target=current}
        else {
            let ordinary=home==(try? CodexAccountTransitionTarget.canonicalHome(NSHomeDirectory()+"/.codex")) || known.contains(home)
            let groups:[CodexLoginGroup]=ordinary ? []:try codexLoginGroupStore.list()
            let independent=ordinary ? false:try codexIndependentLoginStore.contains(home:home)
            guard ordinary
                    || independent || groups.contains(where:{(try? CodexAccountTransitionTarget.canonicalHome($0.home))==home}) else{throw AppError.message("확인할 Codex 홈을 다시 선택해주세요.")}
            target = .init(home:home,executable:groups.isEmpty ? "codex":targets.first?.executable ?? "codex")
        }
        func current(_ value:CodexAccountTransitionTarget,_ records:[ProcessRecord])->Bool {
            value.witnesses.allSatisfy{w in records.contains{$0.pid==w.pid && $0.started==w.started && "/dev/"+$0.tty==w.tty && $0.agent == .codex}}
        }
        guard current(target,rows) else{throw AppError.message("계정 확인 전 세션 연결이 바뀌었습니다.")}
        let result=try await codexAccountInspectionServices.read(target)
        try Task.checkCancellation()
        guard epoch==codexAccountTransitionEpoch,!remoteInputStopped,result.home==home,
              result.connectedSessions==target.witnesses.count else{throw CancellationError()}
        let fresh=try await Task.detached(priority:.utility){try reader()}.value
        let live=try await targetReader(fresh)
        try Task.checkCancellation()
        guard epoch==codexAccountTransitionEpoch,!remoteInputStopped,current(target,fresh),
              live.first(where:{$0.home==home})==targets.first(where:{$0.home==home}) else{
            throw AppError.message("계정 확인 중 서버·세션 연결이 바뀌었습니다. 다시 확인해주세요.")
        }
        return result
    }
    public func codexSessionAccount(sessionID:String) async throws -> CodexSessionAccount {
        guard let session=sessions[sessionID],session.agent == .codex,session.phase != .ended else {throw AppError.message("실행 중인 Codex 세션을 선택해주세요.")}
        let targets=try await codexLoginTargets()
        guard let target=targets.first(where:{$0.witnesses.contains(where:{$0.pid==session.pid && $0.started==session.started && $0.tty==session.tty})}) else {throw AppError.message(codexAttachmentWaitReasons[sessionID].map{"이 세션은 아직 독립 실행 중입니다. "+$0} ?? "이 세션의 실제 연결 서버를 확인하지 못했습니다.")}
        let sharedName=try await codexLoginGroups().first(where:{(try? CodexAccountTransitionTarget.canonicalHome($0.home))==target.home})?.name
        let dedicatedName=try await codexIndependentLogins().first(where:{$0.usesDedicatedServer && (try? CodexAccountTransitionTarget.canonicalHome($0.home))==target.home})?.name
        let groupName=sharedName ?? dedicatedName
        let (identity,server)=try await CodexServerAccountIdentity.read(home:target.home)
        let connected=await Task.detached(priority:.utility) {
            target.witnesses.filter{CodexServerLocation.connectedHome(pid:$0.pid,hints:[target.home],peerPID:server)==target.home}
        }.value
        guard !Task.isCancelled,!remoteInputStopped,let current=sessions[sessionID],current.pid==session.pid,current.started==session.started,current.phase != .ended,
              connected.contains(where:{$0.pid==session.pid && $0.started==session.started}) else {throw AppError.message("계정 조회 중 세션 연결이 바뀌었습니다. 다시 확인해주세요.")}
        var verified=target;verified.witnesses=connected
        return .init(sessionID:sessionID,target:verified,identity:identity,sharedSessions:connected.count,loginGroupName:groupName,serverPID:server)
    }
    /// Current transport association only. Migration must still acquire native
    /// barriers and establish complete ownership before changing either home.
    func codexNativeRuntime(sessionID:String) async throws ->CodexNativeRuntimePair {
        guard let original=sessions[sessionID],original.agent == .codex,original.phase != .ended else {
            throw AppError.message("실행 중인 Codex 세션을 선택해주세요.")
        }
        let account=try await codexSessionAccount(sessionID:sessionID)
        guard let server=account.serverPID,server>0 else{throw AppError.message("실제 연결 서버를 확인하지 못했습니다.")}
        let clientPIDs=account.target.witnesses.map(\.pid)
        let census=try await CodexNativeRuntimePair.resolveCensus(home:account.target.home,serverPID:server,clientPIDs:clientPIDs)
        guard let runtime=census.first(where:{$0.connection.tuiPeer.pid==UInt32(original.pid)}),
              census.count==clientPIDs.count else{throw AppError.message("이 세션의 창을 전체 app-server 연결 목록에 연결하지 못했습니다.")}
        guard !Task.isCancelled,!remoteInputStopped,let current=sessions[sessionID],
              current.pid==original.pid,current.started==original.started,current.tty==original.tty,current.phase != .ended,
              runtime.connection.tuiPeer.pid==UInt32(original.pid),runtime.connection.serverPeer.pid==UInt32(server) else {
            throw AppError.message("제어 연결을 확인하는 중 원래 세션이나 서버가 바뀌었습니다.")
        }
        return runtime
    }
    public func codexSessionServerLink(sessionID:String) async throws ->CodexSessionServerLink {
        try CodexFeatureSupport.requireConnectionInventory()
        guard let original=sessions[sessionID],original.agent == .codex,original.phase != .ended else {
            throw AppError.message("실행 중인 Codex 세션을 선택해주세요.")
        }
        let account=try await codexSessionAccount(sessionID:sessionID)
        guard let server=account.serverPID,server>0 else{throw AppError.message("세션의 app-server 프로세스를 확인하지 못했습니다.")}
        let clientPIDs=account.target.witnesses.map(\.pid)
        let census=try await CodexNativeRuntimePair.resolveCensus(home:account.target.home,serverPID:server,clientPIDs:clientPIDs)
        guard let runtime=census.first(where:{$0.connection.tuiPeer.pid==UInt32(original.pid)}),
              census.count==clientPIDs.count else{throw AppError.message("이 세션의 창을 전체 app-server 연결 목록에 연결하지 못했습니다.")}
        guard !Task.isCancelled,!remoteInputStopped,let current=sessions[sessionID],
              current.pid==original.pid,current.started==original.started,current.tty==original.tty,
              current.cwd==original.cwd,current.phase != .ended,
              runtime.connection.tuiPeer.pid==UInt32(original.pid),runtime.connection.serverPeer.pid==UInt32(server) else {
            throw AppError.message("연결을 확인하는 동안 세션이나 서버가 바뀌었습니다. 다시 확인해주세요.")
        }
        return .init(sessionID:sessionID,sessionPID:original.pid,serverPID:server,
            serverGeneration:runtime.connection.serverGeneration,connectionID:runtime.connection.connectionID,
            logicalBackendID:runtime.connection.logicalBackendID,clientCount:census.count,
            serverConnectionCount:runtime.connection.serverConnectionIDs.count)
    }
    public func checkCodexAccountTransitions() async {
        guard codexAccountCheckTask==nil,!codexAccountTransitionBusy else{return}
        let epoch=codexAccountTransitionEpoch
        let task=Task { [weak self] in
            guard let self else{return}
            await self.performCodexAccountTransitionCheck(epoch:epoch)
        }
        codexAccountCheckTask=task
        await withTaskCancellationHandler(operation:{await task.value},onCancel:{task.cancel()})
        if epoch==codexAccountTransitionEpoch {
            codexAccountCheckTask=nil
            if codexAccountNativeWakePending {codexAccountNativeWakePending=false;codexAccountTransitionSignal.notify()}
        }
    }
    private func recordCodexLoginRefresh(home:String,id:String) throws {
        guard UUID(uuidString:id) != nil else {throw AppError.message("Codex 로그인 대상을 다시 확인해주세요.")}
        let home=try CodexAccountTransitionTarget.canonicalHome(home)
        var requests=codexAccountLoginRequests;requests[home]=id
        try store.set(Self.codexAccountLoginRequestsKey,String(decoding:JSONEncoder().encode(requests),as:UTF8.self))
        codexAccountLoginRequests=requests
    }
    private func recordNativeCodexLoginRefresh(home:String,id:String) throws {
        guard !recordedNativeCodexLoginIDs.contains(id) else{return}
        try recordCodexLoginRefresh(home:home,id:id)
        recordedNativeCodexLoginIDs.insert(id)
    }
    private func codexAccountControlBlockReason()->String? {
        if remoteInputStopped {return "앱이 종료 중이어서 새 로그인·전환 요청을 받지 않습니다."}
        if agentAccounts.busy {return agentAccounts.nativeCodexLogin?.active == true
            ? "브라우저 로그인이 진행 중입니다. 브라우저에서 로그인을 완료하거나 로그인 취소를 누른 뒤 다시 확인해주세요."
            : "Claude 또는 Codex 로그인이 진행 중입니다. 해당 로그인의 완료·취소 상태를 확인해주세요."}
        if let state=codexAccountTransitionStates.sorted(by:{$0.key<$1.key}).first(where:{$0.value.held})?.value {
            return "기존 계정 전환을 확인 중입니다. "+state.detail
        }
        if codexAccountTransitionBusy {return "서버·세션 상태를 확인 중입니다. 현재 확인이 끝나면 다시 시도할 수 있습니다."}
        return nil
    }
    /// Repeated requests join the in-flight inspection, then reconcile its
    /// original journal instead of creating a new login/restart receipt.
    private func joinCodexAccountControl(home:String) async throws->Bool {
        let epoch=codexAccountTransitionEpoch,deadline=Date().addingTimeInterval(20)
        let joinedExisting=codexAccountTransitionStates[home]?.held == true
        while codexAccountTransitionBusy {
            guard !Task.isCancelled,epoch==codexAccountTransitionEpoch,!remoteInputStopped else{throw CancellationError()}
            if agentAccounts.busy {throw AppError.message(codexAccountControlBlockReason()!)}
            guard Date()<deadline else{throw AppError.message(codexAccountControlBlockReason() ?? "현재 서버·세션 확인이 끝나기를 기다립니다.")}
            try await Task.sleep(for:.milliseconds(100))
        }
        guard epoch==codexAccountTransitionEpoch,!Task.isCancelled else{throw CancellationError()}
        if remoteInputStopped || agentAccounts.busy {throw AppError.message(codexAccountControlBlockReason()!)}
        if joinedExisting || codexAccountTransitionHeld {
            guard joinedExisting || codexAccountTransitionStates[home]?.held == true else{throw AppError.message(codexAccountControlBlockReason()!)}
            if codexAccountTransitionStates[home]?.held == true {
                try codexAccountCoordinators[home]?.prioritizeExistingTransition()
                await checkCodexAccountTransitions()
            }
            codexAccountTransitionSignal.notify()
            codexAccountTransitionNotice=codexAccountTransitionStates[home]?.detail
            return true
        }
        return false
    }
    private func revokeUnspentCodexToolHostGrants(home:String) {
        for var state in codexSessionAttachments.values.filter({$0.home==home && [.needsPause,.waitingPause,.needsTab,.ready].contains($0.phase) && ($0.authorizedToolHosts?.isEmpty == false || $0.goalBeforePause != nil)}) {
            state.authorizedToolHosts=nil
            if state.goalBeforePause != nil,state.phase != .needsPause {state.exitNotStarted=true;state.phase = .review;state.detail="재연결 요청이 끝나 남은 Goal 연결을 보류했습니다. 원래 창과 Goal 상태를 확인해주세요. 중단·종료 입력을 반복하지 않습니다."}
            else {state.detail="직접 재연결 요청이 끝나 도구 호스트 정리 허용을 해제했습니다. 자동 연결은 남은 작업이 끝나기를 기다립니다."}
            do {try saveCodexSessionAttachment(state)}
            catch {
                // Revoke in memory even if disk is unavailable. Restoration
                // always drops grants, so the stale disk value cannot re-arm.
                codexSessionAttachments[state.context.session.id]=state
                codexSessionAttachmentNotice="도구 호스트 정리 허용을 해제했습니다. 연결 기록 저장을 확인해주세요."
            }
        }
    }
    public func reconnectCodexLogin(home:String,loginRequestID:String?=nil) async throws {
        // Explicit reconnect first advances standalone-session attachment.
        // Account refresh must wait until an exit/launch has been verified.
        let attachmentHome=try CodexAccountTransitionTarget.canonicalHome(home)
        if try await joinCodexAccountControl(home:attachmentHome) {return}
        if CodexFeatureSupport.canAttachOpenStandaloneSessions && !CodexFeatureSupport.canUsePrivateSessionAttachment {
            await attachOfficialStandaloneCodexSessions(home:attachmentHome,allowActive:true)
            let pending=try cohortRestartDriver().active().filter{($0.plan.sourceHome==attachmentHome || $0.plan.destinationHome==attachmentHome) && $0.phase != .captured}
            guard pending.isEmpty else{throw AppError.message("현재 세션의 재연결을 먼저 마쳐주세요. 저장된 복원 단계에서 계속할 수 있습니다.")}
            let reader=processReader
            let remaining=try await Task.detached(priority:.utility){try reader().filter{record in
                guard record.agent == .codex,record.tty != "??" else{return false}
                let environment=ProcessEnvironment.read(record,names:["HOME","CODEX_HOME"])
                let home=environment?["CODEX_HOME"] ?? environment?["HOME"].map({$0+"/.codex"})
                return home.flatMap{try? CodexAccountTransitionTarget.canonicalHome($0)}==attachmentHome &&
                    CodexServerLocation.connectedHome(pid:record.pid,hints:[attachmentHome])==nil
            }}.value
            guard remaining.isEmpty else{throw AppError.message("원래 독립 세션의 입력·질문 상태를 확인한 뒤 재연결해주세요. "+(codexSessionAttachmentNotice ?? "기존 실행을 유지했습니다."))}
            try await reconnectCodexManagedLogin(home:attachmentHome,loginRequestID:loginRequestID)
            return
        }
        if !CodexFeatureSupport.canUsePrivateSessionAttachment {
            try await reconnectCodexManagedLogin(home:attachmentHome,loginRequestID:loginRequestID)
            return
        }
        // A signed-out shared server can recover its saved login independently
        // of standalone TUIs. Never stop/migrate unrelated work just to restore
        // the already connected cohort, or bypass a partly executed attachment.
        let recoveryEpoch=codexAccountTransitionEpoch
        let inspection:CodexAccountInspection?
        let recoveryRecords:[ProcessRecord]
        // Reserve lookup before suspending, just like the managed reconnect.
        // Automatic checks and another manual request cannot take ownership
        // while the recovery cohort is being proved.
        codexAccountTransitionBusy=true
        do {
            defer{if recoveryEpoch==codexAccountTransitionEpoch {codexAccountTransitionBusy=false}}
            inspection=try? await inspectCodexAccount(home:attachmentHome)
            let reader=processReader
            recoveryRecords=try await Task.detached(priority:.utility){try reader()}.value
            try Task.checkCancellation()
            guard recoveryEpoch==codexAccountTransitionEpoch,!remoteInputStopped else {throw CancellationError()}
        }
        if let inspection,inspection.comparison == .different,inspection.identity?.authenticated == false,
           inspection.connectedSessions>0,
           !codexSessionAttachments.values.contains(where:{$0.home==attachmentHome && $0.phase != .connected && RemoteDiagnostics.isCurrent($0,records:recoveryRecords)}) {
            try await reconnectCodexManagedLogin(home:attachmentHome,loginRequestID:loginRequestID)
            return
        }
        let grantReader=processReader
        let grantRecords=try await Task.detached(priority:.utility){try grantReader()}.value
        let roots=Set(ProcessDiscovery.sessions(grantRecords).filter{$0.agent == .codex}.map(\.id))
        var grants:[String:[ProcessRecord]]=[:]
        for process in grantRecords where roots.contains(process.key) {grants[process.key]=CodexSessionAttachment.toolHosts(process:process,records:grantRecords)}
        codexAttachmentToolHostGrants[attachmentHome]=grants
        defer {
            codexAttachmentToolHostGrants.removeValue(forKey:attachmentHome)
            revokeUnspentCodexToolHostGrants(home:attachmentHome)
        }
        // Only an explicit request may discard a Goal pause plan whose input
        // was proved absent. Rediscover its current thread/Goal from scratch.
        let unsent=codexSessionAttachments.values.filter{$0.home==attachmentHome && grants[$0.context.session.id] != nil && $0.canRetryUnsentGoalPause}.map{$0.context.session.id}
        if !unsent.isEmpty {
            var journal=codexSessionAttachments;for id in unsent {journal.removeValue(forKey:id)}
            try store.set("codexSessionAttachments",String(decoding:JSONEncoder().encode(journal),as:UTF8.self));codexSessionAttachments=journal
        }
        // A cancelled pre-exit Goal request can be resumed only after the same
        // Goal is independently observed paused. Never send its interrupt again.
        for var state in codexSessionAttachments.values.filter({$0.home==attachmentHome && $0.phase == .review && $0.exitNotStarted == true}) {
            guard let prior=state.goalBeforePause,let thread=state.context.conversationID,
                  grantRecords.contains(where:{$0.key==state.context.session.id}),
                  let paused=try CodexSessionAttachment.goalIfPresent(home:attachmentHome,threadID:thread),paused.status == .paused,
                  paused.instanceID==prior.instanceID,paused.createdAt==prior.createdAt,paused.objective==prior.objective,paused.tokenBudget==prior.tokenBudget else{continue}
            state.pausedGoal=paused;state.exitNotStarted=nil;state.context.deadline=Date().addingTimeInterval(120)
            state.phase = state.replacesTab && state.context.shell.tty==state.originalLogin?.tty ? .needsTab:.ready
            try saveCodexSessionAttachment(state)
        }
        // Only a user-triggered reconnect may retry a tab effect proved absent.
        // Unknown outcomes retain review and never create a second tab.
        for var state in codexSessionAttachments.values.filter({$0.home==attachmentHome && $0.phase == .review && $0.replacesTab && $0.preparationNotStarted == true}) {
            state.phase = .needsTab;state.preparationNotStarted=nil
            state.detail="사용자 요청으로 시작되지 않은 복구 탭 준비를 다시 확인합니다."
            try saveCodexSessionAttachment(state)
        }
        for var state in codexSessionAttachments.values.filter({$0.home==attachmentHome && [.ready,.needsTab].contains($0.phase)}) {
            state.authorizedToolHosts=grants[state.context.session.id] ?? []
            try saveCodexSessionAttachment(state)
        }
        let attachmentEpoch=codexAccountTransitionEpoch,attachmentReader=processReader
        let standalone=try await Task.detached(priority:.utility){
            try attachmentReader().contains {record in
                record.agent == .codex && record.tty != "??" && CodexServerLocation.executable(record) != nil && CodexServerLocation.connectedHome(pid:record.pid,hints:[attachmentHome])==nil
            }
        }.value
        if standalone || codexSessionAttachments.values.contains(where:{$0.home==attachmentHome && [.needsPause,.pauseReserved,.waitingPause,.needsTab,.tabReserved,.exitReserved,.waitingShell,.launchReserved,.verifying].contains($0.phase)}) {
            // A manual attempt can recover an earlier automatic setup failure.
            let status=try await codexManagedServerStatus(home:attachmentHome)
            let ready=status.canPrepare ? try await prepareCodexManagedServer(home:attachmentHome):status
            guard ready.phase == .running else{throw AppError.message(ready.detail)}
            codexAttachmentHomes.insert(attachmentHome)
            await ensureCodexManagedServers()
        }
        guard attachmentEpoch==codexAccountTransitionEpoch,!Task.isCancelled else{throw CancellationError()}
        let attachmentDeadline=Date().addingTimeInterval(125)
        while codexSessionAttachments.values.contains(where:{$0.home==attachmentHome && [.needsPause,.pauseReserved,.waitingPause,.needsTab,.tabReserved,.ready,.exitReserved,.waitingShell,.launchReserved,.verifying].contains($0.phase)}) {
            guard !Task.isCancelled,attachmentEpoch==codexAccountTransitionEpoch,!remoteInputStopped,!agentAccounts.busy else{throw CancellationError()}
            guard Date()<attachmentDeadline else{throw AppError.message("기존 세션 연결 결과를 확인하고 있습니다. 같은 종료·실행 입력을 반복하지 않습니다.")}
            try await Task.sleep(for:.seconds(2));await ensureCodexManagedServers()
        }
        if let issue=codexSessionAttachments.values.first(where:{$0.home==attachmentHome && grants[$0.context.session.id] != nil && ($0.phase == .review || $0.goalBeforePause != nil && $0.stoppedThread==nil)}) {throw AppError.message("기존 세션 연결을 완료하지 못했습니다. "+issue.detail)}
        let remaining=try await Task.detached(priority:.utility){try attachmentReader()}.value
        for session in ProcessDiscovery.sessions(remaining) where grants[session.id] != nil && session.agent == .codex && CodexServerLocation.connectedHome(pid:session.pid,hints:[attachmentHome])==nil {
            if let selected=try? await CodexReplyTransport.selectedQueueTarget(session),selected.home==attachmentHome {throw AppError.message("기존 세션 연결이 남아 계정 전환을 보류했습니다. "+(codexSessionAttachmentNotice ?? "원래 작업과 Goal 상태를 확인해주세요."))}
        }
        try await reconnectCodexManagedLogin(home:attachmentHome,loginRequestID:loginRequestID)
    }
    private func reconnectCodexManagedLogin(home:String,loginRequestID:String?) async throws {
        if try await joinCodexAccountControl(home:home) {return}
        let epoch=codexAccountTransitionEpoch
        var ownsBusy=true
        codexAccountTransitionBusy=true
        defer {if ownsBusy,epoch==codexAccountTransitionEpoch {codexAccountTransitionBusy=false}}
        let home=try CodexAccountTransitionTarget.canonicalHome(home)
        let targets=try await codexLoginTargets()
        try Task.checkCancellation()
        guard epoch==codexAccountTransitionEpoch,!remoteInputStopped else {throw CancellationError()}
        guard !codexAccountTransitionHeld,!agentAccounts.busy else {throw AppError.message(codexAccountControlBlockReason() ?? "현재 연결 상태를 확인해주세요.")}
        guard targets.contains(where:{$0.home==home}) else {
            if let issue=codexSessionAttachments.values.filter({$0.home==home && $0.phase == .review}).sorted(by:{$0.context.session.pid<$1.context.session.pid}).first {
                throw AppError.message("기존 세션 연결을 완료하지 못했습니다. "+issue.detail)
            }
            throw AppError.message("이 홈의 관리형 서버에 연결된 세션이 아직 없습니다. "+(codexSessionAttachmentNotice ?? "기존 대화의 연결 상태를 확인해주세요."))
        }
        try persistCodexAccountTransitionEnabled(true)
        let requestID=loginRequestID ?? UUID().uuidString
        try recordCodexLoginRefresh(home:home,id:requestID)
        if loginRequestID != nil {recordedNativeCodexLoginIDs.insert(requestID)}
        for var state in codexSessionAttachments.values.filter({$0.home==home && $0.phase == .connected && $0.stoppedThread != nil && $0.continuationLoginRequestID==nil}) {state.continuationLoginRequestID=requestID;try saveCodexSessionAttachment(state)}
        var failures=codexNativeAttachmentFailures;failures.remove(home)
        try store.set("codexNativeAttachmentFailures.v1",String(decoding:JSONEncoder().encode(Array(failures).sorted()),as:UTF8.self));codexNativeAttachmentFailures=failures
        codexNativeAttachmentPending.remove(home)
        codexAccountTransitionBusy=false;ownsBusy=false
        if codexAccountCheckTask != nil {codexAccountNativeWakePending=true}
        await checkCodexAccountTransitions()
        codexAccountTransitionSignal.notify()
    }
    private func performCodexAccountTransitionCheck(epoch:UUID) async {
        guard epoch==codexAccountTransitionEpoch else{return}
        guard !remoteInputStopped, !codexAccountTransitionBusy,codexNativeAttachmentPending.isEmpty,
              !codexSessionAttachments.values.contains(where:{[.needsPause,.pauseReserved,.waitingPause,.needsTab,.tabReserved,.exitReserved,.waitingShell,.launchReserved,.verifying].contains($0.phase)}),
              codexAccountTransitionEnabled || codexAccountTransitionHeld else { return }
        codexAccountTransitionBusy = true; defer {if epoch==codexAccountTransitionEpoch {codexAccountTransitionBusy = false}}
        do {
            let reader = processReader
            let records = try await Task.detached(priority: .utility) { try reader() }.value
            let targets = try await codexAccountTargetReader(records)
            guard !Task.isCancelled, epoch == codexAccountTransitionEpoch else { return }
            guard Set(targets.map(\.home)).count == targets.count else { throw AppError.message("같은 Codex 홈의 연결이 중복되어 전환을 보류했습니다.") }
            try updateCodexAccountMembership(targets)
            let visible = ProcessDiscovery.sessions(records).filter { $0.agent == .codex && $0.phase != .ended }.count
            let covered = targets.reduce(0) { $0 + $1.witnesses.count }
            let homes=Set(targets.map(\.home))
            let journal=codexAccountTransitionStates.filter {home,state in
                homes.contains(home) || state.phase != .unsupported || state.restartReserved || !state.reservations.isEmpty || !(state.resumeReservations ?? [:]).isEmpty || !state.threads.isEmpty || !state.witnesses.isEmpty
            }
            if journal.count != codexAccountTransitionStates.count {
                try store.set(Self.codexAccountJournalKey,String(decoding:JSONEncoder().encode(journal),as:UTF8.self))
                codexAccountTransitionStates=journal
                codexAccountCoordinators=codexAccountCoordinators.filter{journal[$0.key] != nil}
            }
            codexAccountTransitionNotice = targets.isEmpty ? "관리형 Codex 서버 연결을 아직 확인하지 못했습니다. 실행 중인 Codex를 유지하고 연결을 다시 확인해주세요."
                : visible > covered ? "Codex \(visible - covered)개는 관리형 서버 연결을 확인하지 못해 자동 전환에서 제외했습니다." : nil
            for target in targets.sorted(by: { $0.home < $1.home }) {
                if codexNativeAttachmentFailures.contains(target.home) || codexSessionAttachments.values.contains(where:{plan in plan.home==target.home && plan.goalBeforePause != nil && (plan.phase == .review && records.contains(where:{$0.key==plan.context.session.id}) || plan.phase == .connected && plan.stoppedThread==nil)}) {codexAccountTransitionNotice="기존 Goal의 서버 연결을 먼저 확인해주세요. 계정 전환은 보류했습니다.";continue}
                guard !Task.isCancelled, epoch == codexAccountTransitionEpoch else { return }
                if codexAccountCoordinators[target.home] == nil || (codexAccountCoordinators[target.home]?.target != target && codexAccountTransitionStates[target.home]?.held != true) {
                    let home = target.home
                    let coordinator = CodexAccountTransitionCoordinator(target: target, state: codexAccountTransitionStates[home],
                        services: codexAccountTransitionServices, save: { [weak self] state in
                            guard let self, epoch == self.codexAccountTransitionEpoch else { throw CancellationError() }
                            var journal = self.codexAccountTransitionStates; journal[home] = state
                            try self.store.set(Self.codexAccountJournalKey, String(decoding: JSONEncoder().encode(journal), as: UTF8.self))
                        }, changed: { [weak self] state in
                            guard let self, epoch == self.codexAccountTransitionEpoch else { return }
                            let previous=self.codexAccountTransitionStates[home]
                            self.codexAccountTransitionStates[home] = state
                            if previous?.phase != state.phase {self.invalidateCodexAccountInspection(home:home)}
                            if previous?.held != true, state.held {
                                self.holdCodexAccountInputs(home:home)
                                self.startCodexAccountMembershipRefresh()
                            }
                        })
                    codexAccountCoordinators[home] = coordinator
                    codexAccountTransitionStates[home] = coordinator.state
                }
                // A cancelled task cannot retract bytes already dispatched.
                // Drain all owned input transports before interrupting a turn.
                if codexAccountTransitionStates[target.home]?.held == true, !codexAccountInputsDrained(home:target.home) { continue }
                let native=agentAccounts.nativeCodexLogin
                let nativeHome=native?.resolvedHome ?? native.flatMap{try? CodexAccountTransitionTarget.canonicalHome($0.home)}
                if nativeHome==target.home,native?.active==true {continue}
                // Bind each successful job once, even before its queued
                // completion callback. A later manual reconnect must retain
                // its newer receipt rather than inherit the old job again.
                if nativeHome==target.home,native?.phase=="succeeded",let id=native?.id {
                    try recordNativeCodexLoginRefresh(home:target.home,id:id)
                }
                let stopped=codexSessionAttachments.values.filter{$0.home==target.home && $0.phase == .connected && $0.continuationLoginRequestID != nil && $0.continuationLoginRequestID==codexAccountLoginRequests[target.home]}.compactMap(\.stoppedThread)
                await codexAccountCoordinators[target.home]?.check(loginRequestID:codexAccountLoginRequests[target.home],preStoppedGoals:stopped)
            }
            for home in codexAccountTransitionStates.keys where codexAccountTransitionStates[home]?.held == true && !targets.contains(where: { $0.home == home }) {
                let detail = "원래 Codex 서버·창을 찾지 못했습니다. 자동 명령을 반복하지 않고 대기합니다."
                if let coordinator = codexAccountCoordinators[home] { try coordinator.targetUnavailable() }
                else {
                    var state = codexAccountTransitionStates[home]!
                    state.phase = .review; state.detail = detail
                    var journal = codexAccountTransitionStates; journal[home] = state
                    try store.set(Self.codexAccountJournalKey, String(decoding: JSONEncoder().encode(journal), as: UTF8.self))
                    codexAccountTransitionStates = journal
                }
            }
        } catch {
            guard epoch == codexAccountTransitionEpoch else { return }
            codexAccountObservedTargets=[];codexAccountMembershipVerifiedAt=nil
            codexAccountTransitionNotice = error.localizedDescription
        }
    }
    public func cancelCodexAccountTransition(home: String) throws {
        guard !codexAccountTransitionBusy else { throw AppError.message("현재 계정 확인·전환 결과를 기다려주세요.") }
        if let coordinator = codexAccountCoordinators[home] { try coordinator.cancel(); return }
        guard var state = codexAccountTransitionStates[home], state.canCancel else { return }
        state.phase = .cancelled; state.detail = "나머지 자동 전환을 중지했습니다. 이미 중단한 작업은 대기 상태로 유지합니다."
        var journal = codexAccountTransitionStates; journal[home] = state
        try store.set(Self.codexAccountJournalKey, String(decoding: JSONEncoder().encode(journal), as: UTF8.self))
        codexAccountTransitionStates = journal
    }
    private func codexAccountInputsDrained(home:String)->Bool {
        sessions.values.filter { $0.agent == .codex && codexAccountTransitionInputHeld($0,home:home) }.allSatisfy { session in
            !automaticInputBusy(session.id) && !remoteInputSessions.contains(session.id) && !sendingMessages.contains(session.id) &&
                !changingGoals.contains(session.id) && !session.questions.contains { replyingQuestions.contains($0.id) }
        }
    }
    private func holdCodexAccountInputs(home:String) {
        // Each affected session has its own cancellation epoch and dispatch
        // barrier. A global revision also cancels unrelated queued approvals.
        for id in sessions.keys where sessions[id].map({$0.agent == .codex && codexAccountTransitionInputHeld($0,home:home)}) == true {
            automationRuntime.reset(id)
            screens[id]?.scheduledID = nil
            cancelCodexProgressCheck(id); codexProgressTrackers.removeValue(forKey: id)
            cancelModelRetention(id); cancelCapacityResume(id)
            for question in sessions[id]?.questions ?? [] { cancelAutomaticQuestionReply(question.id) }
        }
        publish()
    }
    private func startCodexManagedServerPolling() {
        guard codexManagedServerAutomaticTask==nil else{return}
        codexManagedServerAutomaticTask=Task { [weak self] in
            while !Task.isCancelled {
                await self?.ensureCodexManagedServers()
                do {try await Task.sleep(for:.seconds(self?.codexSessionAttachments.values.contains(where:{![.connected,.review].contains($0.phase)}) == true ? 2:30))} catch {break}
            }
        }
    }
    private func startCodexAccountTransitionPolling() {
        guard codexAccountTransitionTask == nil else { return }
        let observation=codexAccountTransitionSignal.observe()
        codexAccountTransitionTask = Task { [weak self] in
            await observation.waitForChange(timeout:0)
            while !Task.isCancelled, let self {
                await self.checkCodexAccountTransitions()
                let delay: Double = self.codexAccountTransitionHeld && !self.codexAccountTransitionStates.values.allSatisfy({ !$0.held || $0.phase == .review }) ? 2 : 30
                await observation.waitForChange(timeout:delay)
            }
        }
    }
    private func codexProgressToken(_ id:String,at date:Date)->String? {
        guard let value=codexProgressHistory[id],date.timeIntervalSince(value.at)>=(-5),date.timeIntervalSince(value.at)<20 else {return nil}
        let turn=codexTurns[id]?.state
        return value.token+":"+(turn?.turnID ?? "")+":"+(turn?.status ?? "")
    }
    private func codexProgressFinishedTurn(_ id:String)->String? {
        guard let turn=codexTurns[id],abs(Date().timeIntervalSince(turn.observedAt))<20,
              let status=turn.state.status,["completed","failed","interrupted"].contains(status) else {return nil}
        return status
    }
    private func codexProgressEligible(_ session:AgentSession,allowInterrupted:Bool=false)->Bool {
        !hasManualGoalHold(session.id) && !hasOSPermissionWait(session.id) && !remoteInputStopped && snapshot.codexProgressRecoveryEnabled != false && !snapshot.paused && session.automatic &&
            session.agent == .codex && session.terminal == .terminal && session.channel == .terminalScreen && session.phase != .ended &&
            (codexProgressFinishedTurn(session.id)==nil || allowInterrupted && codexProgressFinishedTurn(session.id)=="interrupted")
    }
    private func observeCodexProgress(_ id:String,raw:String,generation:String,at now:Date) {
        guard let session=sessions[id] else {codexProgressTrackers.removeValue(forKey:id);return}
        if codexProgressJobs[id] != nil {return}
        if session.agent == .codex,session.terminal == .terminal,session.phase == .working,let finished=codexProgressFinishedTurn(id) {
            codexProgressTrackers.removeValue(forKey:id)
            let label=finished=="completed" ? "완료":finished=="failed" ? "실패":"중단"
            sessions[id]?.codexProgressRecovery = .init(phase:.review,lastProgressAt:session.codexProgressRecovery?.lastProgressAt ?? codexTurns[id]!.observedAt,detail:"대화 기록에서는 현재 차례가 \(label) 상태입니다. 화면의 Working 표시만으로 자동 중단하거나 다시 실행하지 않습니다.",historyAvailable:true)
            return
        }
        guard codexProgressEligible(session),session.phase == .working,
              !session.pendingInTerminal,session.unansweredQuestions.allSatisfy({$0.hasLaterUserMessage == true}),
              let fingerprint=CodexProgressScreen.workingFingerprint(raw) else {
            codexProgressTrackers.removeValue(forKey:id)
            if session.codexProgressRecovery?.phase != .review {sessions[id]?.codexProgressRecovery=nil}
            return
        }
        let token=codexProgressToken(id,at:now)
        var tracker:CodexProgressTracker
        if let current=codexProgressTrackers[id] {tracker=current;tracker.observe(fingerprint:fingerprint,generation:generation,at:now,historyToken:token)}
        else {
            let previous=store.value("codexProgressRecovery:"+id).flatMap {try? JSONDecoder().decode(CodexProgressRecovery.self,from:Data($0.utf8))}
            tracker = .init(fingerprint:fingerprint,generation:generation,at:now,historyToken:token,previous:previous)
        }
        if tracker.status.checks>=3,now.timeIntervalSince(tracker.status.lastProgressAt)>=codexProgressTimeout {
            tracker.set(.review,detail:"자동 진행 확인을 3회 시도했습니다. 원래 Codex의 진행 상황을 직접 확인해주세요.")
        }
        codexProgressTrackers[id]=tracker;sessions[id]?.codexProgressRecovery=tracker.status
        if tracker.isDue(at:now,timeout:codexProgressTimeout),!userInputHasPriority(id) {try? requestCodexProgressCheck(id)}
    }
    private func saveCodexProgress(_ id:String) throws {
        guard let value=codexProgressTrackers[id]?.status else {return}
        try store.set("codexProgressRecovery:"+id,String(decoding:JSONEncoder().encode(value),as:UTF8.self))
    }
    public func cancelCodexProgressCheck(_ id:String) {
        guard codexProgressJobs.removeValue(forKey:id) != nil else {return}
        codexProgressTrackers[id]?.set(.review,detail:"진행 확인을 취소했습니다. 이미 전달된 입력은 원래 Terminal에서 확인해주세요.")
        sessions[id]?.codexProgressRecovery=codexProgressTrackers[id]?.status
        try? saveCodexProgress(id);publish()
    }
    public func requestCodexProgressCheck(_ id:String) throws {
        guard let session=sessions[id],codexProgressEligible(session),session.phase == .working,
              !session.pendingInTerminal,!userInputHasPriority(id),!automaticInputBusy(id),codexProgressJobs[id]==nil,
              session.unansweredQuestions.allSatisfy({$0.hasLaterUserMessage == true}),
              let observed=remoteObservedScreens[id],abs(Date().timeIntervalSince(observed.observedAt))<6,
              let fingerprint=CodexProgressScreen.workingFingerprint(observed.raw),let adapter=screenAdapters[.terminal] else {
            throw RemoteHTTPError(409,"자동 승인이 켜진 원래 Terminal의 Codex 작업 화면과 빈 입력창을 먼저 확인해주세요.")
        }
        if codexProgressTrackers[id]==nil {codexProgressTrackers[id] = .init(fingerprint:fingerprint,generation:observed.generation,at:Date(),historyToken:codexProgressToken(id,at:Date()))}
        guard codexProgressTrackers[id]?.status.phase != .review else {throw RemoteHTTPError(409,"이전 확인의 전달 결과를 원래 Terminal에서 확인해주세요. 새 진척 신호를 감지하면 감시를 재개합니다.")}
        if let checked=codexProgressTrackers[id]?.status.checkedAt,Date().timeIntervalSince(checked)<30 {throw RemoteHTTPError(409,"최근 진행 확인 요청을 이미 처리했습니다. 원래 Codex의 반영 결과를 확인해주세요.")}
        let job=UUID(),history=codexProgressToken(id,at:Date()),generation=observed.generation
        codexProgressJobs[id]=job
        automationRuntime.launch(id) {[weak self] epoch in
            guard let self else {return}
            await self.performCodexProgressCheck(session,adapter:adapter,job:job,epoch:epoch,generation:generation,fingerprint:fingerprint,history:history)
        }
    }
    private func performCodexProgressCheck(_ original:AgentSession,adapter:ScreenHostAdapter,job:UUID,epoch:UInt64,generation:String,fingerprint:String,history:String?) async {
        let id=original.id
        var interruptWasSent=false
        func authorized()->Bool {
            guard !Task.isCancelled,codexProgressJobs[id]==job,automationRuntime.epoch(id)==epoch,
                  let current=sessions[id],codexProgressEligible(current,allowInterrupted:interruptWasSent),!userInputHasPriority(id),
                  current.pid==original.pid,current.started==original.started,current.tty==original.tty,
                  !current.pendingInTerminal,current.phase != .approval,current.phase != .input,
                  current.unansweredQuestions.allSatisfy({$0.hasLaterUserMessage == true}),
                  remoteObservedScreens[id]?.generation==generation else {return false}
            return true
        }
        guard authorized(),!automaticInputBusy(id) else {codexProgressJobs.removeValue(forKey:id);return}
        automaticInputSessions.insert(id)
        defer {automaticInputSessions.remove(id);if codexProgressJobs[id]==job {codexProgressJobs.removeValue(forKey:id)};scheduleScreenApproval(id);publish()}
        func stage(_ phase:CodexProgressRecovery.Phase,_ detail:String,attempt:Bool=false) throws {
            guard authorized() else {throw CancellationError()}
            codexProgressTrackers[id]?.set(phase,detail:detail,at:attempt ? Date():nil)
            sessions[id]?.codexProgressRecovery=codexProgressTrackers[id]?.status
            try saveCodexProgress(id);publish()
        }
        let reader=processReader,identityReader=terminalInputIdentity
        var event=AuditEvent(sessionID:id,summary:"Codex 진행 확인·이어가기",outcome:"진행 확인 준비",source:"Codex 진척 확인",context:AuditContext(session:original),request:"진척 신호가 없는 원래 Codex 확인",answer:CodexProgressRecovery.prompt)
        do {
            let live=try await Task.detached(priority:.utility) {try reader()}.value
            guard authorized(),let process=live.first(where:{$0.pid==original.pid && $0.started==original.started && "/dev/"+$0.tty==original.tty && $0.agent == .codex}),process.isForeground else {throw AppError.message("원래 CLI의 실행 정보가 바뀌었습니다.")}
            guard let identity=identityReader(original.pid),identity.processStart==original.started,identity.foregroundGroup==identity.processGroup else {throw AppError.message("원래 Codex의 직접 입력 연결을 확인해주세요.")}
            let target=ScreenTarget(tty:original.tty,jobPIDs:live.filter {$0.tty==process.tty && $0.processGroup==process.processGroup}.map(\.pid),sourcePID:original.pid,sourceStarted:original.started,sourceIdentity:identity)
            func read() async throws -> String {
                guard authorized() else {throw CancellationError()}
                let snapshot=try await Task.detached(priority:.utility) {try adapter.readForValidation([target])}.value
                guard authorized(),snapshot.failures.isEmpty,snapshot.screens.filter({$0.tty==target.tty}).count==1,let raw=snapshot.screens.first(where:{$0.tty==target.tty})?.contents else {throw AppError.message("원래 Codex 화면을 새로 확인하지 못했습니다.")}
                return raw
            }
            func send(_ input:RemoteTerminalInput,expected:String) async throws {
                let single=singleProcessReader
                let verified=try await Task.detached(priority:.utility) {try single(original.pid).contains {$0.pid==original.pid && $0.started==original.started && "/dev/"+$0.tty==original.tty && $0.agent == .codex && $0.isForeground}}.value
                guard authorized(),verified else {throw CancellationError()}
                let result=try await Task.detached(priority:.utility) {try adapter.input(target,expected,.codex,input)}.value
                guard result == .sent else {throw AppError.message("입력 전달을 확인하지 못했습니다. 원래 Codex 화면을 확인해주세요.")}
            }
            let before=try await read()
            guard CodexProgressScreen.workingFingerprint(before)==fingerprint,codexProgressToken(id,at:Date())==history else {throw AppError.message("새 진척 신호나 입력을 감지해 중단하지 않았습니다.")}
            guard log(event) else {throw AppError.message("진행 확인 기록을 저장하지 못했습니다.")}
            try stage(.interrupting,"진행 여부를 확인하기 위해 원래 Codex에 Esc를 한 번 보냅니다.",attempt:true)
            try await send(.init(kind:.escape),expected:before)
            interruptWasSent=true
            event.outcome="Esc 전달 · 입력 대기 확인 중";_ = log(event)
            try stage(.waiting,"중단 후 빈 입력창을 확인하고 있습니다. 추가 Esc는 보내지 않습니다.")
            let deadline=Date().addingTimeInterval(codexProgressWaitSeconds)
            var ready:String?,previous:String?
            while Date()<deadline {
                try await Task.sleep(for:.milliseconds(300))
                let raw=try await read()
                if CodexProgressScreen.ready(raw) {
                    if previous==raw {ready=raw;break};previous=raw
                } else {
                    previous=nil
                    guard CodexProgressScreen.workingFingerprint(raw) != nil else {throw AppError.message("입력창·승인 요청이 바뀌어 진행 확인 메시지를 보내지 않았습니다.")}
                }
            }
            guard let ready else {throw AppError.message("Codex가 입력 대기로 돌아왔는지 확인하지 못했습니다. 자동 재입력 없이 원래 창 확인을 기다립니다.")}
            try stage(.asking,"진행 상황 보고 후 기존 작업을 이어가도록 요청합니다.")
            try await send(.init(kind:.submit,text:CodexProgressRecovery.prompt),expected:ready)
            event.outcome="진행 보고·이어가기 요청 전달";_ = log(event)
            try stage(.requested,"진행 보고·이어가기 요청을 전달했습니다. 새 출력과 기록 갱신을 계속 확인합니다.")
        } catch {
            event.outcome="진행 확인 중단·원본 확인 필요: "+String(error.localizedDescription.prefix(600));_ = log(event)
            if codexProgressJobs[id]==job {
                codexProgressTrackers[id]?.set(.review,detail:Task.isCancelled ? "자동 진행 확인이 취소됐습니다. 원래 Terminal의 입력 상태를 확인해주세요.":String(error.localizedDescription.prefix(1000)))
                sessions[id]?.codexProgressRecovery=codexProgressTrackers[id]?.status;try? saveCodexProgress(id)
            }
        }
    }

    private func scheduleCapacityResume(_ id: String) {
        guard !hasOSPermissionWait(id),!remoteInputStopped, !automationNeedsFreshScreen.contains(id), systemSafetyStates[id]?.notice.isPending != true,
              let state = capacityStates[id], state.phase == .waiting, state.scheduledID == nil, !snapshot.paused, !userInputHasPriority(id), !automaticInputBusy(id) else { return }
        let scheduledID = UUID(), scheduledRevision = revision
        capacityStates[id]?.scheduledID = scheduledID
        let delay = max(0, state.deadline.timeIntervalSinceNow)
        automationRuntime.launch(id) { [weak self] epoch in
            if delay > 0 { do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) } catch { return } }
            guard !Task.isCancelled, let self, self.automationRuntime.epoch(id) == epoch else { return }
            await self.dispatchCapacityResume(id, scheduledID: scheduledID, revision: scheduledRevision, automationEpoch: epoch)
        }
    }

    private func dispatchCapacityResume(_ id: String, scheduledID: UUID, revision scheduledRevision: UInt64, automationEpoch: UInt64) async {
        func current() -> (CapacityState, AgentSession, ScreenHostAdapter?)? {
            guard !hasOSPermissionWait(id),!Task.isCancelled, automationRuntime.epoch(id) == automationEpoch, !automationNeedsFreshScreen.contains(id),
                  let state = capacityStates[id], state.scheduledID == scheduledID, state.phase == .waiting,
                  revision == scheduledRevision, !snapshot.paused, !userInputHasPriority(id), !automaticInputBusy(id), let session = sessions[id], session.automatic,
                  // Preserve async questions in history, but do not let questions
                  // followed by later user input block a fresh error/Goal retry.
                  session.unansweredQuestions.allSatisfy({ $0.hasLaterUserMessage == true }),
                  session.phase != .ended, (session.channel == state.channel || ScreenHost(kind:session.terminal)?.channel == state.channel), Date() >= state.deadline,
                  Date().timeIntervalSince(state.observedAt) < 6 else { return nil }
            let adapter = ScreenHost(channel:state.channel).flatMap {screenAdapters[$0]}
            guard adapter != nil || (state.channel == .vscodeScreen && session.bridgeID.flatMap({peers[$0]}) != nil) else { return nil }
            return (state, session, adapter)
        }
        guard current() != nil else {
            // A later frame reschedules a stop that is still visible.
            if capacityStates[id]?.scheduledID == scheduledID { capacityStates[id]?.scheduledID = nil }
            return
        }
        let reader = processReader
        let live = try? await Task.detached(priority: .utility) { try reader() }.value
        guard let (state, session, adapter) = current(),
              let process = live?.first(where: { $0.pid == session.pid && $0.started == session.started && $0.agent == session.agent
                  && "/dev/" + $0.tty == session.tty }), process.isForeground else {
            if capacityStates[id]?.scheduledID == scheduledID { capacityStates[id]?.scheduledID = nil }
            return
        }
        capacityStates[id]?.phase = .sending; capacityStates[id]?.scheduledID = nil
        capacityStates[id]?.dispatchID = scheduledID
        var event = AuditEvent(sessionID: id, summary: "\(state.stop.kind.title) · 이어서 진행 요청 (\(state.attempt))",
            outcome: "이어서 진행 요청 · 결과 미확인", source: state.channel.title, context: AuditContext(session: session),
            request: state.stop.region, answer: state.stop.continuationText)
        // Persist the attempt before typing; a crash or lost result remains traceable.
        guard log(event) else { capacityStates[id]?.phase = .review; publish(); return }
        sessions[id]?.interruption?.resumeUncertain = true
        sessions[id]?.interruption?.resumeConfirmedAt = nil
        sessions[id]?.interruption?.resumeIdentity = state.stop.continuationKey
        sessions[id]?.interruption?.resumeCommand = state.stop.continuationText
        sessions[id]?.interruption?.resumeStop = state.stop
        sessions[id]?.interruption?.resumeSubmissionCancelled = false
        let turnIdentity = failedTurnIdentity(id, at: Date())
        capacityStates[id]?.turnIdentity = turnIdentity
        sessions[id]?.interruption?.resumeTurnIdentity = turnIdentity
        guard persistInterruption(id) else { capacityStates[id]?.phase = .review; publish(); return }
        publish()
        let job = (live ?? []).filter { $0.tty == process.tty && $0.processGroup == process.processGroup }.map(\.pid)
        let target = ScreenTarget(tty: session.tty, handle: session.screenHandle, jobPIDs: job,
            sourcePID: session.pid, sourceStarted: session.started)
        let region = state.stop.region, text = state.stop.continuationText
        automaticInputSessions.insert(id)
        var superseded = false
        defer {
            automaticInputSessions.remove(id); scheduleScreenApproval(id)
            if superseded { scheduleCapacityResume(id) }
        }
        func ownsDelivery() -> Bool {
            !hasOSPermissionWait(id) && !Task.isCancelled && automationRuntime.epoch(id) == automationEpoch &&
                capacityStates[id]?.phase == .sending && capacityStates[id]?.dispatchID == scheduledID
                && sessions[id]?.phase != .ended
        }
        do {
            let delivery: ResumeDelivery
            if let adapter {
                if state.submitOnly, let complete = adapter.completeResume {
                    let stop = state.stop
                    delivery = try await Task.detached { try complete(target,stop) }.value
                } else if state.submitOnly { delivery = .typed }
                else { delivery = try await Task.detached { try adapter.resume(target,region,text) }.value }
            } else { delivery = try await resumeBridgeSession(session,stop:state.stop,submitOnly:state.submitOnly,automationEpoch:automationEpoch) }
            // Always retain the actual result, but an old callback cannot change a
            // replacement failure, a cancelled run, or a session that has ended.
            switch delivery {
            case .sent: event.outcome = "이어서 진행 요청 전달"
            case .draft: event.outcome = "재시도 입력 작성 확인 · Enter 제출 대기"
            case .typed: event.outcome = "입력 확인 필요 · 이어서 진행 전송 미확인"
            case .screenChanged, .missingTarget, .agentMissing:
                event.outcome = "입력 미전달 · 새 화면 확인 (\(delivery.rawValue))"
            }
            guard ownsDelivery() else { superseded = true; log(event); publish(); return }
            switch delivery {
            case .sent:
                sessions[id]?.interruption?.resumeUncertain = false
                sessions[id]?.interruption?.resumeConfirmedAt = Date()
                capacityStates[id]?.phase = .sent; capacityStates[id]?.sentAt = Date(); capacityStates[id]?.unsent = 0
            case .draft:
                // Only a complete, owned, unsubmitted body authorizes Return again.
                // The text itself is never retyped by this path.
                capacityStates[id]?.submitOnly = true
                capacityStates[id]?.phase = .waiting
                capacityStates[id]?.deadline = Date().addingTimeInterval(capacityUnsentRetryDelay)
            case .typed:
                // Typed, but neither a draft nor a new message was visible: never type again.
                capacityStates[id]?.phase = .review
            case .screenChanged, .missingTarget, .agentMissing:
                // Nothing was typed. A temporary target or screen failure must not
                // permanently stop recovery. Back off and require another fresh frame.
                retryUnsentCapacity(id)
            }
        } catch {
            let notStarted = (error as? RemoteHTTPError)?.diagnostics?["delivery"] == "not_started"
            event.outcome = (notStarted ? "입력 미전달: " : "입력 확인 필요: ") + error.localizedDescription
            guard ownsDelivery() else { superseded = true; log(event); publish(); return }
            if notStarted { retryUnsentCapacity(id) }
            // The write may have happened; an uncertain input is never repeated.
            else { capacityStates[id]?.phase = .review }
        }
        capacityStates[id]?.dispatchID = nil
        log(event)
        persistInterruption(id)
        publish()
    }

    private func retryUnsentCapacity(_ id: String) {
        guard let state = capacityStates[id] else { return }
        // A rejected Return does not undo the text already written earlier.
        sessions[id]?.interruption?.resumeUncertain = state.submitOnly
        let unsent = state.unsent + 1
        capacityStates[id]?.unsent = unsent
        capacityStates[id]?.phase = .waiting
        let delays = recoveryDelays(for: state.stop.kind)
        let delay = unsent <= 1 || delays.isEmpty ? capacityUnsentRetryDelay :
            max(capacityUnsentRetryDelay, delays[min(unsent - 2, delays.count - 1)])
        capacityStates[id]?.deadline = Date().addingTimeInterval(delay)
    }

    @discardableResult private func persistInterruption(_ id: String) -> Bool {
        guard let value = sessions[id]?.interruption else { return true }
        do {
            try store.set("interruption:\(id)",String(decoding:try JSONEncoder().encode(value),as:UTF8.self))
            return true
        } catch { snapshot.health.auditError = "작업 중단 상태를 저장하지 못했습니다. \(error.localizedDescription)"; return false }
    }

    private func resumeBridgeSession(_ session: AgentSession, stop: CodexCapacityStop, submitOnly: Bool = false, automationEpoch: UInt64) async throws -> ResumeDelivery {
        let id = session.id
        let region = stop.region, text = stop.continuationText
        guard let before = remoteObservedScreens[id], Date().timeIntervalSince(before.observedAt) < 6,
              submitOnly ? CodexResumeCheck.draftReady(before.raw, stop: stop) : CodexResumeCheck.ready(before.raw,region:region,text:text) else { return .screenChanged }
        func write(_ observed: RemoteObservedScreen, kind: String, value: String) async throws -> Bool {
            let reader = processReader, live = try await Task.detached { try reader() }.value
            guard !Task.isCancelled, automationRuntime.epoch(id) == automationEpoch, !remoteInputStopped, !snapshot.paused, !userInputHasPriority(id),
                  live.contains(where:{$0.pid == session.pid && $0.started == session.started && $0.agent == session.agent && "/dev/"+$0.tty == session.tty && $0.isForeground}),
                  let current = sessions[id], current.automatic, current.bridgeID == session.bridgeID, current.terminalID == session.terminalID,
                  let peerID = session.bridgeID, let peer = peers[peerID], let terminalID = session.terminalID,
                  remoteObservedScreens[id]?.raw == observed.raw, remoteObservedScreens[id]?.generation == observed.generation else { return false }
            let actionID = UUID().uuidString
            return try await withCheckedThrowingContinuation { continuation in
                remoteInputReplies[actionID] = (peerID,continuation)
                if !peer.send(["method":"remoteInput","id":actionID,"terminalID":terminalID,"screen":observed.raw,
                    "generation":String(observed.generation.dropFirst(peerID.count+1)),"kind":kind,"text":value,
                    "expiresAt":Date().addingTimeInterval(2).timeIntervalSince1970*1000]) {
                    remoteInputReplies.removeValue(forKey:actionID)?.continuation.resume(throwing:AppError.message("원본 편집기 연결이 끊겼습니다.")); return
                }
                Task { [weak self] in
                    try? await Task.sleep(for:.seconds(3))
                    self?.remoteInputReplies.removeValue(forKey:actionID)?.continuation.resume(throwing:AppError.message("원본 편집기의 입력 결과를 확인하지 못했습니다."))
                }
            }
        }
        if !submitOnly { guard try await write(before,kind:"characters",value:text) else { return .screenChanged } }
        let deadline = Date().addingTimeInterval(8)
        repeat {
            try await Task.sleep(for:.milliseconds(250))
            guard let after = remoteObservedScreens[id], after.generation == before.generation else { return .typed }
            let state = CodexResumeCheck.state(before:before.raw,after:after.raw,region:region,text:text)
            if state == .submitted { return .sent }
            if state == .draft {
                try await Task.sleep(for: .milliseconds(750))
                guard let stable = remoteObservedScreens[id], Date().timeIntervalSince(stable.observedAt) < 6,
                      CodexResumeCheck.draftReady(stable.raw, stop: stop) else { return .typed }
                guard try await write(stable,kind:"enter",value:"") else { return .typed }
                let until = Date().addingTimeInterval(4)
                repeat {
                    try await Task.sleep(for:.milliseconds(250))
                    if let next = remoteObservedScreens[id], next.generation == before.generation,
                       CodexResumeCheck.state(before:before.raw,after:next.raw,region:region,text:text) == .submitted { return .sent }
                } while Date() < until
                return remoteObservedScreens[id].map { CodexResumeCheck.draftReady($0.raw, stop: stop) } == true ? .draft : .typed
            }
        } while Date() < deadline
        return .typed
    }

    private func rememberExitContext(_ session: AgentSession, records: [ProcessRecord], byPID: inout [Int32:ProcessRecord]?) {
        guard session.automatic, session.phase != .ended else { return }
        if byPID == nil { byPID = ProcessDiscovery.index(records) }
        guard let byPID,
              // A fresh process snapshot can briefly contain both sides of PID
              // reuse. The ancestry index intentionally keeps its first entry,
              // but the managed session must bind to its exact start identity.
              let indexedProcess = byPID[session.pid],
              let process = indexedProcess.started == session.started
                ? indexedProcess
                : records.first(where: { $0.pid == session.pid && $0.started == session.started }),
              let shell = ProcessDiscovery.ancestors(of:process.parent,byPID:byPID).first(where: {
                  $0.tty == process.tty && SessionExitRecovery.isShell($0)
              }) else { return }
        let conversation = session.agent == .codex ? questionThreadBySession[session.id] : session.providerID
        var context = SessionExitRecovery(session:session,process:process,shell:shell,conversationID:conversation)
        context.conversationID = context.conversationID ?? exitRecoveries[session.id]?.conversationID
        context.codexLaunch = exitRecoveries[session.id]?.codexLaunch
        exitRecoveries[session.id] = context
        if session.agent == .codex,context.codexLaunch == nil,exitLaunchReads[session.id] == nil {
            let id=session.id,pid=session.pid,started=session.started
            let read=Task.detached(priority:.utility) {try? CodexSessionLaunch.capture(process)}
            exitLaunchReads[id]=read
            Task { [weak self] in
                let captured=await read.value
                guard let self,!read.isCancelled,!remoteInputStopped,
                      exitRecoveries[id]?.session.pid==pid,exitRecoveries[id]?.session.started==started else{return}
                exitRecoveries[id]?.codexLaunch=captured
                if sessions[id]?.phase == .ended {saveExitRecoveries()}
            }
        }
    }

    private func readRecoveryConversation(_ id: String) {
        guard let session = sessions[id], session.phase != .ended, session.interruption?.needsAttention == true,
              exitRecoveries[id]?.conversationID == nil,
              conversationReads.insert(id).inserted else { return }
        let current = records
        let epoch = automationRuntime.epoch(id)
        Task { [weak self] in
            guard let self else { return }
            defer { conversationReads.remove(id) }
            let value = await currentPTYConversation(session,records:current)
            guard !Task.isCancelled, automationRuntime.epoch(id) == epoch, let value, UUID(uuidString:value) != nil else { return }
            exitRecoveries[id]?.conversationID = value.lowercased()
            if sessions[id]?.phase == .ended { saveExitRecoveries() }
        }
    }

    private func prepareExitRecovery(_ id: String) {
        guard let session = sessions[id], let error = session.interruption, error.needsAttention else { return }
        sessions[id]?.interruption?.processEnded = true
        let eligible = session.automatic && error.kind.retryable && error.resumeUncertain != true && capacityStates[id]?.phase != .cancelled
        if var context = exitRecoveries[id] {
            context.session = sessions[id] ?? session
            context.conversationID = context.conversationID ?? SessionExitRecovery.conversation(in:remoteObservedScreens[id]?.raw ?? "")
            context.state = eligible ? "scheduled" : "review"
            context.deadline = Date().addingTimeInterval(recoveryDelays(for: error.kind).first ?? 5)
            exitRecoveries[id] = context
            sessions[id]?.interruption?.recoveryStatus = context.state
            sessions[id]?.interruption?.recoveryDetail = eligible ? "원본 셸과 같은 대화를 확인한 뒤 자동 복구합니다." : "자동 복구가 꺼졌거나 입력 결과 확인이 필요합니다."
        } else {
            sessions[id]?.interruption?.recoveryStatus = "unavailable"
            sessions[id]?.interruption?.recoveryDetail = "원본 셸을 확인할 수 없습니다. Mac에서 같은 대화를 다시 열어주세요."
        }
        persistInterruption(id); saveExitRecoveries()
    }

    @discardableResult private func saveExitRecoveries() -> Bool {
        let values = exitRecoveries.values.compactMap { value -> SessionExitRecovery? in
            guard let session = sessions[value.session.id], session.interruption?.processEnded == true,
                  session.interruption?.needsAttention == true,
                  Date().timeIntervalSince(session.interruption?.date ?? .distantPast) < 7 * 86400 else { return nil }
            var result = value; result.session = session; return result
        }.sorted { ($0.session.interruption?.date ?? .distantPast) < ($1.session.interruption?.date ?? .distantPast) }.suffix(100)
        let notices = sessions.values.filter { $0.phase == .ended && $0.interruption?.needsAttention == true &&
            Date().timeIntervalSince($0.interruption?.date ?? .distantPast) < 7 * 86400 }.sorted { $0.lastActivity < $1.lastActivity }.suffix(100)
        do {
            try store.setValues(["interruptedSessions":String(decoding:try JSONEncoder().encode(Array(values)),as:UTF8.self),
                "interruptedSessionNotices":String(decoding:try JSONEncoder().encode(Array(notices)),as:UTF8.self)])
            return true
        }
        catch { snapshot.health.auditError = "종료된 세션의 복구 상태를 저장하지 못했습니다. \(error.localizedDescription)"; return false }
    }

    private func advanceExitRecovery(_ id: String, records: [ProcessRecord], byPID: inout [Int32: ProcessRecord]?) {
        guard let context = exitRecoveries[id], sessions[id]?.interruption?.needsAttention == true else { return }
        // A connection that was unavailable at exit can return later. Recheck the
        // original shell/conversation then; never require another app restart.
        if context.state == "unavailable", context.automaticCancelled != true,
           sessions[id]?.automatic == true, !snapshot.paused, !remoteInputStopped,
           let host = ScreenHost(kind: context.session.terminal), screenConnections[host]?.enabled == true,
           screenAdapters[host]?.restart != nil {
            exitRecoveries[id]?.state = "scheduled"
            exitRecoveries[id]?.deadline = Date().addingTimeInterval(30)
            sessions[id]?.interruption?.recoveryStatus = "scheduled"
            persistInterruption(id); saveExitRecoveries(); publish()
            return
        }
        if context.state == "awaiting" {
            if Date().timeIntervalSince(context.deadline ?? .distantPast) > 120 {
                sessions[id]?.interruption?.recoveryStatus = "review"
                sessions[id]?.interruption?.recoveryDetail = "복구 명령은 전달했지만 같은 대화의 실행을 확인하지 못했습니다. Mac의 원본 터미널을 확인해주세요."
            }
            if byPID == nil { byPID = ProcessDiscovery.index(records) }
            guard let byPID else { return }
            let candidates = records.filter { process in
                process.agent == context.session.agent && process.tty == context.shell.tty && process.key != id &&
                ProcessDiscovery.ancestors(of: process.parent, byPID: byPID).contains { $0.pid == context.shell.pid && $0.started == context.shell.started }
            }
            guard candidates.count == 1, let process = candidates.first, let next = sessions[process.key],
                  conversationReads.insert(id).inserted else { return }
            Task { [weak self] in
                guard let self else { return }; defer { conversationReads.remove(id) }
                let conversation = next.agent == .codex ? questionThreadBySession[next.id] : next.providerID
                let actual: String?
                if let conversation { actual = conversation } else { actual = await currentPTYConversation(next,records:records) }
                guard let actual, actual.lowercased() == context.conversationID?.lowercased(),
                      sessions[next.id]?.phase != .ended, !snapshot.paused, !remoteInputStopped,
                      exitRecoveries[id]?.state == "awaiting",
                      exitRecoveries[id]?.conversationID == context.conversationID else { return }
                sessions[id]?.interruption?.resumedSessionID = next.id
                sessions[id]?.interruption?.recoveredAt = Date()
                sessions[id]?.interruption?.resumeUncertain = false
                sessions[id]?.interruption?.recoveryStatus = "recovered"
                if exitRecoveries[id]?.automaticCancelled != true {
                    sessions[next.id]?.automatic = true
                    try? store.set("automatic:\(next.id)","true")
                }
                persistInterruption(id); exitRecoveries.removeValue(forKey:id)
                exitLaunchReads.removeValue(forKey:id)?.cancel();saveExitRecoveries(); publish()
            }
            return
        }
        guard context.state == "scheduled", !snapshot.paused, !remoteInputStopped,
              !userInputHasPriority(id), Date() >= (context.deadline ?? .distantPast),
              exitRecoveryTasks[id] == nil else { return }
        let token = UUID(), scheduledRevision = revision
        exitRecoveryTasks[id] = token
        Task { [weak self] in
            guard let self else { return }
            defer { if exitRecoveryTasks[id] == token { exitRecoveryTasks.removeValue(forKey: id) } }
            await restartExitedSession(id, token: token, scheduledRevision: scheduledRevision)
        }
    }

    private func restartExitedSession(_ id: String, token: UUID, scheduledRevision: UInt64) async {
        func owns(_ phase: String) -> Bool {
            exitRecoveryTasks[id] == token && exitRecoveries[id]?.state == phase
        }
        func mayLaunch() -> Bool {
            owns("scheduled") && revision == scheduledRevision && !snapshot.paused && !remoteInputStopped
                && !userInputHasPriority(id) && sessions[id]?.phase == .ended
                && sessions[id]?.interruption?.needsAttention == true
        }
        guard mayLaunch(), var context = exitRecoveries[id] else { return }
        guard let host = ScreenHost(kind:context.session.terminal),
              screenConnections[host]?.enabled == true, let adapter = screenAdapters[host], let restart = adapter.restart else {
            sessions[id]?.interruption?.recoveryStatus = "unavailable"
            sessions[id]?.interruption?.recoveryDetail = "이 원본 터미널은 종료 후 자동 복구 입력을 지원하지 않습니다. Mac에서 같은 대화를 다시 열어주세요."
            exitRecoveries[id]?.state = "unavailable"; persistInterruption(id); saveExitRecoveries(); publish(); return
        }
        let reader = processReader
        var launched = false
        do {
            let live = try await Task.detached { try reader() }.value
            guard mayLaunch() else { return }
            guard let shell = context.verifiedShell(in:live) else {
                sessions[id]?.interruption?.recoveryDetail = "원본 셸이 닫혔거나 다른 작업 중입니다. 원본 셸이 돌아오면 다시 확인합니다."
                exitRecoveries[id]?.deadline = Date().addingTimeInterval(30); publish(); return
            }
            let target = ScreenTarget(tty:context.session.tty,handle:context.session.screenHandle,jobPIDs:[shell.pid],sourcePID:shell.pid,sourceStarted:shell.started)
            let first = try await Task.detached { try adapter.readForValidation([target]).screens.first(where:{$0.tty == target.tty})?.contents }.value
            guard mayLaunch() else { return }
            guard let first, SessionExitRecovery.emptyShellPrompt(first) else {
                exitRecoveries[id]?.deadline = Date().addingTimeInterval(30)
                sessions[id]?.interruption?.recoveryDetail = "원본 셸의 빈 입력창을 기다리고 있습니다."; publish(); return
            }
            context.conversationID = context.conversationID ?? SessionExitRecovery.conversation(in:first)
            guard let conversation=context.conversationID,UUID(uuidString:conversation) != nil,
                  context.session.agent == .codex || context.command != nil else {
                exitRecoveries[id]?.state = "unavailable"
                sessions[id]?.interruption?.recoveryStatus = "unavailable"
                sessions[id]?.interruption?.recoveryDetail = "정확한 대화 ID를 확인하지 못했습니다. Mac에서 원래 대화를 선택해주세요."
                persistInterruption(id); saveExitRecoveries(); publish(); return
            }
            let command:String,launchContext:CodexCLIContext?
            if context.session.agent == .codex {
                if context.codexLaunch == nil,let pending=exitLaunchReads[id] {
                    context.codexLaunch=await pending.value
                    guard mayLaunch() else{return}
                }
                guard let saved=context.codexLaunch else {
                    exitRecoveries[id]?.state="review"
                    sessions[id]?.interruption?.recoveryStatus="review"
                    sessions[id]?.interruption?.recoveryDetail="원래 Codex의 로그인 홈을 확인하지 못했습니다. 원본 로그인 홈에서 같은 대화를 다시 열어주세요."
                    persistInterruption(id);saveExitRecoveries();publish();return
                }
                let official=try await Task.detached(priority:.utility) {try saved.officialContext()}.value
                guard mayLaunch() else{return}
                command=try official.terminalInvocation(["resume",conversation,CodexCapacityStop.resumeText]).map(HookInstaller.quote).joined(separator:" ")
                launchContext=official
            } else {
                guard let planned=context.command else {throw AppError.message("복구 명령을 확인하지 못했습니다.")}
                command=planned;launchContext=nil
            }
            try await Task.sleep(for:.seconds(1))
            guard mayLaunch() else { return }
            let fresh = try await Task.detached { try reader() }.value
            guard mayLaunch(), context.verifiedShell(in:fresh) != nil else { return }
            let screen = try await Task.detached { try adapter.readForValidation([target]).screens.first(where:{$0.tty == target.tty})?.contents }.value
            guard mayLaunch() else { return }
            guard screen == first else { exitRecoveries[id]?.deadline = Date().addingTimeInterval(30); return }
            context.state = "launching"; context.deadline = Date(); context.attempts += 1; exitRecoveries[id] = context
            sessions[id]?.interruption?.resumeUncertain = true
            sessions[id]?.interruption?.recoveryStatus = "sending"
            sessions[id]?.interruption?.recoveryDetail = "원본 터미널에서 같은 대화를 여는 중입니다."
            guard persistInterruption(id), saveExitRecoveries() else { exitRecoveries[id]?.state = "review"; return }
            let event = AuditEvent(sessionID:id,summary:"오류 종료 · 같은 대화 복구",outcome:"복구 명령 전달 · 결과 미확인",source:host.title,context:AuditContext(session:context.session))
            guard log(event) else { exitRecoveries[id]?.state = "review"; return }
            publish()
            launched = true
            let delivery = try await Task.detached {
                try launchContext?.verifyUnchanged()
                return try restart(target,first,command)
            }.value
            guard owns("launching") else { return }
            if delivery == .sent {
                exitRecoveries[id]?.state = "awaiting"; exitRecoveries[id]?.conversationID = context.conversationID
                sessions[id]?.interruption?.recoveryStatus = "awaiting"
                sessions[id]?.interruption?.recoveryDetail = "같은 대화의 실행을 확인하고 있습니다. 복구 명령은 다시 보내지 않습니다."
            } else {
                exitRecoveries[id]?.state = "scheduled"
                let delays = recoveryDelays(for: sessions[id]?.interruption?.kind ?? .transport)
                let delay = delays.isEmpty ? 30 : delays[min(context.attempts - 1, delays.count - 1)]
                exitRecoveries[id]?.deadline = Date().addingTimeInterval(delay)
                sessions[id]?.interruption?.resumeUncertain = false
                sessions[id]?.interruption?.recoveryStatus = exitRecoveries[id]?.state
                sessions[id]?.interruption?.recoveryDetail = "복구 명령이 전달되지 않았습니다. 원본 셸을 다시 확인합니다."
            }
        } catch {
            // Cancellation while reading must not revive its captured recovery plan.
            // Once writing started, retain uncertainty even if controls changed during the write.
            guard launched ? owns("launching") : mayLaunch() else { return }
            let uncertain = sessions[id]?.interruption?.resumeUncertain == true
            exitRecoveries[id]?.state = uncertain ? "review" : "scheduled"
            exitRecoveries[id]?.deadline = Date().addingTimeInterval(30)
            sessions[id]?.interruption?.recoveryStatus = uncertain ? "review" : "scheduled"
            sessions[id]?.interruption?.recoveryDetail = uncertain ? "복구 입력의 결과를 확인하지 못했습니다. 같은 명령을 다시 보내지 않습니다." : "원본 터미널 연결을 다시 확인합니다. \(error.localizedDescription)"
        }
        persistInterruption(id); saveExitRecoveries(); publish()
    }

    public func cancelCapacityResume(_ id: String) {
        if exitRecoveries[id]?.state == "scheduled" {
            exitRecoveries[id]?.state = "cancelled"
            sessions[id]?.interruption?.recoveryStatus = "cancelled"
            sessions[id]?.interruption?.recoveryDetail = "같은 대화의 자동 복구를 취소했습니다."
            persistInterruption(id); saveExitRecoveries(); publish(); return
        }
        guard let phase = capacityStates[id]?.phase, phase == .waiting || phase == .unavailable else { return }
        capacityStates[id]?.phase = .cancelled; capacityStates[id]?.scheduledID = nil
        sessions[id]?.interruption?.resumeSubmissionCancelled = true
        persistInterruption(id)
        publish()
    }

    // MARK: Independent mouse activity

    public func setMouseActivity(_ enabled: Bool) throws {
        try store.set("mouseActivity", enabled ? "true" : "false")
        mouseActivity.setEnabled(enabled)
        snapshot.mouseActivity = mouseActivity.status
        if enabled { startMouseActivityPolling() }
        else {
            mouseActivityTask?.cancel(); mouseActivityTask = nil
        }
    }

    private func startMouseActivityPolling() {
        guard mouseActivityTask == nil, pollTask != nil, mouseActivity.nextEvaluationDelay != nil else { return }
        mouseActivityTask = Task { [weak self] in
            while !Task.isCancelled, let self {
                self.evaluateMouseActivity()
                guard let delay = self.mouseActivity.nextEvaluationDelay else { return }
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            }
        }
    }

    public func requestMouseActivityPermission() {
        _ = mouseActivity.requestPermission()
        snapshot.mouseActivity = mouseActivity.status
    }

    public func evaluateMouseActivity() {
        mouseActivity.evaluate()
        if snapshot.mouseActivity != mouseActivity.status { snapshot.mouseActivity = mouseActivity.status }
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
        keepAwakeSignal.notify()
        await evaluateKeepAwake()
    }

    /// Turns the setting off and releases a hold first, then removes the rule with an administrator password.
    public func removeKeepAwakeRule() async throws {
        if keepAwakeEnabled { try await setKeepAwake(false) }
        guard !keepAwakeSwitch.owned else { throw AppError.message("잠자기 금지를 먼저 해제하지 못했습니다. 잠시 후 다시 시도해주세요.") }
        let control = powerControl
        try await Task.detached(priority: .userInitiated) { try control.removeRule() }.value
        keepAwakeRule = nil
        keepAwakeSignal.notify()
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
            setKeepAwakeActivity(false)
            setKeepAwakeStatus(KeepAwakeStatus(phase: .off, detail: Self.keepAwakeOff, enabled: false, ruleFile: powerControl.ruleFile()))
            return
        }
        // The app's hold is independent of session discovery and approval state.
        // `sudo -n -l` runs only after turning it on or after a failed change, never on every pass.
        if keepAwakeRule == nil, now >= keepAwakeRetryAfter {
            let control = powerControl
            keepAwakeRule = await Task.detached(priority: .utility) { control.ruleInstalled() }.value
            guard !keepAwakeStopped else { return }
        }
        var reading = powerControl.read()
        let working = KeepAwake.working(snapshot.sessions, paused: snapshot.paused).count
        let blocked = keepAwakeBlock(reading, at: now)
        let wanted = keepAwakeEnabled && keepAwakeRule == true && blocked == nil
        let owned = keepAwakeSwitch.owned
        if owned && reading.sleepDisabled { keepAwakeSwitch.heartbeat() }
        if keepAwakeRule != nil, now >= keepAwakeRetryAfter {
            let floor = keepAwakeBatteryFloor
            if !reading.sleepDisabled {
                if wanted { _ = await changeKeepAwake(at: now) { try await $0.hold(floor: floor) } }
                else if owned { await keepAwakeSwitch.forget() }
            } else if owned {
                if wanted { _ = await changeKeepAwake(at: now) { try await $0.keepWatching(floor: floor) } }
                else { _ = await changeKeepAwake(at: now) { try await $0.release() } }
            }
            reading = powerControl.read()
        }
        guard !keepAwakeStopped else {setKeepAwakeActivity(false);return}
        let holding = keepAwakeSwitch.owned && reading.sleepDisabled
        setKeepAwakeActivity(keepAwakeEnabled && blocked == nil && reading.sleepDisabled)
        setKeepAwakeStatus(keepAwakeStatus(reading, holding: holding, working: working, blocked: blocked))
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

    private func keepAwakeStatus(_ reading: PowerReading, holding: Bool, working: Int, blocked: KeepAwakeStatus.Phase?) -> KeepAwakeStatus {
        let ruleFile = powerControl.ruleFile()
        func status(_ phase: KeepAwakeStatus.Phase, _ detail: String) -> KeepAwakeStatus {
            KeepAwakeStatus(phase: phase, detail: detail, enabled: keepAwakeEnabled, ruleFile: ruleFile, working: working,
                lidClosed:reading.lidClosed,screenLocked:reading.screenLocked,idleDisplaySleepPrevented:keepAwakeActivity != nil)
        }
        if !keepAwakeEnabled { return holding ? status(.holding, "끄는 중입니다. 잠자기 금지를 해제하고 있습니다.") : status(.off, Self.keepAwakeOff) }
        if let failure = keepAwakeFailure { return status(.failed, "잠자기 설정을 바꾸지 못했습니다. 잠시 후 다시 시도합니다. \(failure)") }
        if keepAwakeRule == nil { return status(.checking, Self.keepAwakeChecking) }
        if keepAwakeRule == false { return status(.setup, "관리자 권한 규칙이 없습니다. 끄고 다시 켜면 관리자 암호를 받아 설치합니다.") }
        if reading.sleepDisabled && !holding { return status(.external, "macOS 잠자기 금지가 이미 켜져 있습니다. 직접 켠 설정은 AutoApprove가 바꾸지 않습니다.") }
        if blocked == .lowBattery { return status(.lowBattery, "배터리가 \(keepAwakeBatteryFloor)% 이하라 평소처럼 잠듭니다. 전원을 연결하면 다시 켭니다.") }
        if blocked == .hot { return status(.hot, "Mac이 뜨거워 평소처럼 잠듭니다. 식은 뒤 5분이 지나면 다시 켭니다.") }
        if holding {
            return status(.holding, reading.screenLocked == true ? "앱이 켜진 동안 계속 작업 중 · 화면은 잠겨 있습니다." : "앱이 켜진 동안 잠자기·자동 화면 꺼짐을 방지하고 있습니다.")
        }
        return status(.ready, "앱이 켜진 동안 계속 작업할 수 있도록 잠자기 유지를 준비합니다.")
    }

    private func setKeepAwakeStatus(_ status: KeepAwakeStatus) {
        if snapshot.keepAwake != status { snapshot.keepAwake = status }
    }

    /// While it holds, App Nap must not slow the checks that answer approvals behind a closed lid.
    private func setKeepAwakeActivity(_ on: Bool) {
        if on, keepAwakeActivity == nil {
            keepAwakeActivity = powerControl.activity.begin()
        } else if !on, let activity = keepAwakeActivity {
            powerControl.activity.end(activity); keepAwakeActivity = nil
        }
    }

    private func projectCapacityResumes() {
        var ids = projectedCapacityResumeIDs
        ids.formUnion(capacityStates.keys)
        ids.formUnion(exitRecoveries.keys)
        for id in ids {
            guard sessions[id] != nil else {
                projectedCapacityResumeIDs.remove(id)
                continue
            }
            let presented = capacityResumeProjection(for: id)
            if sessions[id]?.capacityResume != presented { sessions[id]?.capacityResume = presented }
            if presented == nil { projectedCapacityResumeIDs.remove(id) }
            else { projectedCapacityResumeIDs.insert(id) }
        }
    }

    private func capacityResumeProjection(for id: String) -> CapacityResume? {
        if let state = capacityStates[id], sessions[id]?.phase != .ended {
            let phase: CapacityResume.Phase
            switch state.phase {
            case .waiting: phase = snapshot.paused ? .paused : .scheduled
            case .sending: phase = .sending
            case .sent: phase = .awaiting
            case .unavailable: phase = .unavailable
            case .review: phase = .review
            case .cancelled: phase = .cancelled
            }
            var presented = CapacityResume(phase: phase, attempt: state.attempt, limit: 0,
                deadline: phase == .scheduled ? state.deadline : nil, message: state.stop.continuationText)
            presented.reason = state.stop.kind.title
            return presented
        }
        if let recovery = exitRecoveries[id], sessions[id]?.phase == .ended,
           sessions[id]?.interruption?.needsAttention == true, recovery.state != "ready" {
            let phase = snapshot.paused && recovery.state == "scheduled" ? CapacityResume.Phase.paused :
                CapacityResume.Phase(rawValue: sessions[id]?.interruption?.recoveryStatus ?? recovery.state) ?? .review
            var presented = CapacityResume(phase: phase, attempt: max(1, recovery.attempts), limit: 0,
                deadline: phase == .scheduled ? recovery.deadline : nil)
            presented.reason = sessions[id]?.interruption?.kind.title
            return presented
        }
        return nil
    }

    private func retryUnsentApproval(_ id: String, dispatchID: UUID, generation: String) {
        guard let state = screens[id], state.generation == generation, state.dispatchID == dispatchID else { return }
        screens[id]?.dispatchID = nil
        screens[id]?.validationFailures += 1
        // Only a definitive non-write enters this path. A fast repaint must not
        // permanently exhaust a retry budget; back off, then validate the complete
        // dialog at the target again even if no more output/resize event arrives.
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
        let original=sessions[id],validation=original.flatMap {session in
            session.terminal == .terminal ? screenAdapters[.terminal]?.validationScreens:nil
        },reader=processReader
        automationRuntime.launch(id) { [weak self] epoch in
            // A repeated Computer Use permission can have exactly the same text
            // after a brief real turn. Normal 1–2 s polling can miss that turn.
            // Observe only after a definite write, on the same original tab,
            // with a strict four-read/1.25 s start budget. No input is replayed.
            if let original,let validation {
                let target=ScreenTarget(tty:original.tty,handle:original.screenHandle,sourcePID:original.pid,sourceStarted:original.started)
                for delay:UInt64 in [0,60_000_000,140_000_000,300_000_000] {
                    do {if delay>0 {try await Task.sleep(nanoseconds:delay)}} catch {return}
                    guard let self,!Task.isCancelled,self.automationRuntime.epoch(id)==epoch,
                          !self.remoteInputStopped,!self.snapshot.paused,self.sessions[id]?.automatic == true,
                          self.screens[id]?.dispatchID==dispatchID,self.screens[id]?.generation==generation,
                          self.screens[id]?.prompt.requestIdentity==requestIdentity else {return}
                    guard Date().timeIntervalSince(deliveredAt)<1.25 else {break}
                    let readStartedAt=Date()
                    let observed:(String,ScreenAnalysis)?
                    do {
                        observed=try await Task.detached(priority:.userInitiated) {() throws -> (String,ScreenAnalysis)? in
                            let live=try reader()
                            guard live.contains(where:{$0.pid==original.pid && $0.started==original.started && $0.agent==original.agent && "/dev/"+$0.tty==original.tty}) else {return nil}
                            let snapshot=try validation([target]),frames=snapshot.screens.filter {$0.tty==target.tty}
                            guard frames.count==1 else {return nil}
                            let raw=frames[0].contents
                            return (raw,ScreenAnalysis(raw:raw,agent:original.agent))
                        }.value
                    } catch {break}
                    guard !Task.isCancelled,self.automationRuntime.epoch(id)==epoch,!self.remoteInputStopped,
                          !self.snapshot.paused,self.sessions[id]?.automatic == true,
                          self.sessions[id]?.pid==original.pid,self.sessions[id]?.started==original.started,
                          self.sessions[id]?.tty==original.tty,self.sessions[id]?.channel==original.channel,
                          self.screens[id]?.dispatchID==dispatchID,self.screens[id]?.generation==generation else {return}
                    if let observed,observed.1.prompt==nil,observed.1.activity.phase == .working,
                       (self.remoteObservedScreens[id]?.observedAt ?? .distantPast)<=readStartedAt {
                        self.receiveScreen(sessionID:id,raw:observed.0,generation:generation,source:original.channel,at:readStartedAt,
                            precomputed:observed.1,screenContentsUnchanged:false)
                        break
                    }
                }
            }
            let remaining=max(0,8-Date().timeIntervalSince(deliveredAt))
            do {try await Task.sleep(nanoseconds:UInt64(remaining*1_000_000_000))} catch {return}
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
            self.scheduleScreenApproval(action.sessionID)
            self.publish()
        }
    }

    public func codexApprovalConversations(sessionID: String) async throws -> [CodexQueueConversation] {
        guard let session = sessions[sessionID], session.agent == .codex, session.phase != .ended else { throw AppError.message("실행 중인 Codex 세션을 선택해주세요.") }
        let target = try await questionTransport.queueHome(session)
        try validateCodexQueueSession(session, threadID: nil)
        let choices = try await Task.detached { try CodexSubagentApprovals.roots(target: target, cwd: session.cwd) }.value
        try validateCodexQueueSession(session, threadID: nil)
        return choices
    }
    public func connectCurrentCodexApprovals(sessionID: String) async throws {
        guard let session = sessions[sessionID], session.agent == .codex, session.phase != .ended else { throw AppError.message("실행 중인 Codex 세션을 선택해주세요.") }
        if session.codexApprovalBinding != nil { return }
        let thread: String
        var matchedName: String?
        if let known = questionThreadBySession[sessionID] { thread = known }
        else {
            do { thread = try await questionTransport.prepareMessage(session).threadID }
            catch {
                let home = try await questionTransport.queueHome(session)
                let conversations = try await codexQueue.conversations(home, session.cwd)
                try validateCodexQueueSession(session, threadID: nil)
                guard let current = sessions[sessionID],
                      let match = CodexProfileConversationBinding.match(title: current.terminalTitle, cwd: session.cwd, conversations: conversations),
                      let name = match.name else { throw AppError.message("현재 세션의 대화를 확인하지 못했습니다. 대화 연결 확인에서 선택해주세요.") }
                thread = match.id; matchedName = name.precomposedStringWithCanonicalMapping
            }
        }
        try validateCodexQueueSession(session, threadID: thread)
        if let matchedName {
            guard CodexProfileConversationBinding.terminalName(sessions[sessionID]?.terminalTitle, cwd: session.cwd) == matchedName else { throw AppError.message("현재 세션의 대화가 바뀌었습니다.") }
        }
        try await connectCodexApprovals(sessionID: sessionID, threadID: thread)
    }
    private func subagentGoalTarget(_ session:AgentSession,root:String) async throws ->CodexReplyTarget {
        guard session.agent == .codex,session.phase != .ended,session.codexApprovalBinding?.threadID==root else {throw AppError.message("연결된 부모 대화를 다시 확인해주세요.")}
        let target=try await questionTransport.prepareQueue(session,root)
        try validateCodexQueueSession(session,threadID:root)
        guard target.threadID==root,target.queueAvailable,sessions[session.id]?.codexApprovalBinding?.threadID==root else {throw AppError.message("서브에이전트의 연결 서버가 바뀌었습니다.")}
        return target
    }

    public func readCodexSubagentGoal(sessionID:String,childID:String) async throws ->CodexSubagentGoal {
        guard let session=sessions[sessionID],let root=session.codexApprovalBinding?.threadID else {throw AppError.message("부모 대화에 연결한 뒤 Goal을 확인해주세요.")}
        let target=try await subagentGoalTarget(session,root:root)
        let result:CodexSubagentGoal
        do {result=try await codexSubagentGoals.read(target,session.cwd,childID)}
        catch let error as RemoteHTTPError where error.diagnostics?["rpcCode"]=="-32601" {throw AppError.message("이 연결 서버는 서브에이전트 Goal 관리를 지원하지 않습니다. 지원하는 관리형 서버 연결이 필요합니다.")}
        catch let error as CodexControlRPCError where error.reason=="managed child goal control is unavailable" {throw AppError.message("이 연결 서버에서 서브에이전트 Goal 관리가 활성화되지 않았습니다.")}
        let fresh=try await subagentGoalTarget(session,root:root)
        guard fresh.home==target.home,result.rootThreadID==root,result.threadID==childID else {throw AppError.message("서브에이전트의 연결이 바뀌었습니다. 다시 확인해주세요.")}
        return result
    }

    private func scheduleGoalIntentRecovery() {
        guard goalRecoveryTask==nil,Date()>=nextGoalRecovery else{return}
        nextGoalRecovery=Date().addingTimeInterval(30)
        goalRecoveryTask=Task { [weak self] in
            await self?.recoverCodexGoalIntents()
            self?.goalRecoveryTask=nil
        }
    }

    /// Reconcile desired state, never blindly replay an old command or SQL receipt.
    private func goalRecoveryHomes(_ intent:CodexSubagentGoalReceipt.Intent,currentHome:String)throws->[String]? {
        guard let instance=intent.expected.goal?.instanceID else{return nil}
        let original=try CodexAccountTransitionTarget.canonicalHome(intent.home)
        if let homes=try CodexMigrationJournal(store:store).goalMigrationHomes(threadID:intent.expected.threadID,goalID:instance,currentHome:currentHome) {
            guard homes.contains(original) else{return nil}
            return Set(homes+[intent.home,currentHome]).sorted()
        }
        guard try CodexAccountTransitionTarget.canonicalHome(currentHome)==original else{return nil}
        return Set([intent.home,currentHome]).sorted()
    }
    public func recoverCodexGoalIntents() async {
        guard !recoveringGoalIntents,!remoteInputStopped,!snapshot.paused else{return}
        recoveringGoalIntents=true;defer{recoveringGoalIntents=false}
        guard let ledger=try? CodexSubagentGoalActionStore(path:paths.directory.appendingPathComponent("subagent-goal-actions.sqlite").path),
              let pending=try? ledger.pendingIntents() else{return}
        for var receipt in pending {
            guard !Task.isCancelled,!remoteInputStopped,!snapshot.paused else{return}
            guard let intent=receipt.intent else{continue}
            guard (try? ledger.isLatestIntent(receipt.requestID)) == true else {
                receipt.phase = .notStarted;receipt.detail="더 최근 Goal 요청이 있어 이전 요청의 복구를 종료했습니다."
                try? ledger.finish(receipt);continue
            }
            let candidates=sessions.values.filter{$0.agent == .codex && $0.phase != .ended && $0.codexApprovalBinding?.threadID==intent.expected.rootThreadID}
            for session in candidates {
                let key=intent.home+"\u{0}"+intent.expected.threadID
                guard !changingGoalThreads.contains(key),!changingGoals.contains(session.id),!automaticInputBusy(session.id),
                      !userInputHasPriority(session.id),
                      !remoteInputSessions.contains(session.id),!codexAccountInputHeld(session.id),!codexAccountContinuationHeld(session.id) else{continue}
                changingGoalThreads.insert(key);changingGoals.insert(session.id)
                defer{changingGoalThreads.remove(key);changingGoals.remove(session.id)}
                do {
                    let target=try await subagentGoalTarget(session,root:intent.expected.rootThreadID)
                    guard let homes=try goalRecoveryHomes(intent,currentHome:target.home) else{continue}
                    guard try ledger.isLatestIntent(receipt.requestID,homes:homes) else {
                        receipt.phase = .notStarted;receipt.detail="이동한 로그인 홈에 더 최근 Goal 요청이 있어 이전 복구를 종료했습니다."
                        try ledger.finish(receipt);break
                    }
                    let targetKey=target.home+"\u{0}"+intent.expected.threadID
                    guard targetKey==key || !changingGoalThreads.contains(targetKey) else{continue}
                    if targetKey != key {changingGoalThreads.insert(targetKey)}
                    defer{if targetKey != key {changingGoalThreads.remove(targetKey)}}
                    let current=try await codexSubagentGoals.read(target,session.cwd,intent.expected.threadID)
                    guard CodexGoalIntentRecovery.sameGoal(intent.expected,current) else {
                        receipt.phase = .notStarted;receipt.detail="원래 Goal이 교체되거나 변경되어 자동 복구를 종료했습니다."
                        try ledger.finish(receipt);break
                    }
                    let recoveryID=receipt.requestID
                    let authorize:@Sendable () async throws ->Void = {[self] in
                        try Task.checkCancellation()
                        let fresh=try await self.subagentGoalTarget(session,root:intent.expected.rootThreadID)
                        try await MainActor.run {
                        guard !self.remoteInputStopped,!self.snapshot.paused,fresh.home==target.home,
                              !self.automaticInputBusy(session.id),!self.remoteInputSessions.contains(session.id),
                              !self.remoteUserInputHasPriority(session.id),!self.nativeUserInputHasPriority(session.id),
                              !self.codexAccountInputHeld(session.id),!self.codexAccountContinuationHeld(session.id),
                              let currentHomes=try self.goalRecoveryHomes(intent,currentHome:fresh.home),
                              try ledger.isLatestIntent(recoveryID,homes:currentHomes) else{throw CancellationError()}
                        }
                    }
                    try await authorize()
                    let result:CodexSubagentGoal
                    if current.goal?.status==CodexGoalIntentRecovery.desired(intent.action) {
                        if let settle=codexSubagentGoals.settleRecovered {result=try await settle(target,session.cwd,current,authorize)}
                        else{result=current}
                    } else {
                        guard intent.action != .wait else{continue}
                        guard current.goal?.status == (intent.action == .resume ? .paused:.active) else{continue}
                        if let requested=codexSubagentGoals.requestedChange {
                            result=try await requested(target,session.cwd,current,intent.action,UUID(),paths.directory,authorize)
                        } else {result=try await codexSubagentGoals.change(target,session.cwd,current,intent.action,authorize)}
                    }
                    try await authorize()
                    guard CodexGoalIntentRecovery.sameGoal(intent.expected,result),result.goal?.status==CodexGoalIntentRecovery.desired(intent.action),
                          intent.action != .wait || result.executionState=="idle" else{throw AppError.message("요청한 Goal 상태를 아직 확인하지 못했습니다.")}
                    receipt.phase = .confirmed;receipt.result=result;receipt.detail="저장된 요청과 현재 Goal 상태를 대조해 복구했습니다."
                    try ledger.finish(receipt)
                } catch is CancellationError {return}
                catch {receipt.phase = .unknown;receipt.detail="Goal 상태 복구 대기: "+error.localizedDescription;try? ledger.finish(receipt)}
                break
            }
        }
    }

    private final class SubagentGoalDispatch {var started=false}
    public func changeCodexSubagentGoal(sessionID:String,expected:CodexSubagentGoal,action:CodexSubagentGoalAction,requestID:UUID) async throws ->CodexSubagentGoalReceipt {
        guard let session=sessions[sessionID],let goal=expected.goal,
              UUID(uuidString:expected.threadID) != nil,UUID(uuidString:goal.instanceID ?? "") != nil,
              expected.threadID != expected.rootThreadID else {throw AppError.message("현재 서브에이전트 Goal을 다시 확인해주세요.")}
        let target=try await subagentGoalTarget(session,root:expected.rootThreadID)
        let binding=PromptDetector.fingerprint([sessionID,target.home,expected.rootThreadID,expected.threadID,expected.parentThreadID,goal.revision,expected.turnID ?? "",action.rawValue].joined(separator:"\u{0}"))
        let ledger=try CodexSubagentGoalActionStore(path:paths.directory.appendingPathComponent("subagent-goal-actions.sqlite").path)
        if let existing=try ledger.read(requestID) {
            guard existing.binding==binding else {throw AppError.message("다른 Goal 요청에 사용한 식별자입니다.")}
            return existing
        }
        let key=target.home+"\u{0}"+expected.threadID
        let validGoalAction = action == .pause ? goal.status == .active:
            action == .resume ? goal.status == .paused:
                goal.status == .paused && expected.executionState != "idle" && expected.turnID != nil
        guard !changingGoalThreads.contains(key),!changingGoals.contains(sessionID),!automaticInputBusy(sessionID),
              !remoteInputSessions.contains(sessionID),!codexAccountInputHeld(sessionID),!codexAccountContinuationHeld(sessionID),
              validGoalAction else {throw AppError.message("진행 중인 입력·계정 전환 또는 Goal 상태를 먼저 확인해주세요.")}
        changingGoalThreads.insert(key);changingGoals.insert(sessionID)
        defer {changingGoalThreads.remove(key);changingGoals.remove(sessionID)}
        var receipt=CodexSubagentGoalReceipt(requestID:requestID,binding:binding,phase:.reserved,result:nil,detail:"요청 결과를 확인 중입니다. 같은 요청은 다시 보내지 않습니다.",
            intent:.init(sessionID:sessionID,home:target.home,expected:expected,action:action))
        try ledger.reserve(receipt)
        let dispatch=SubagentGoalDispatch()
        do {
            let authorize:@Sendable () async throws ->Void = {[self] in
                let fresh=try await self.subagentGoalTarget(session,root:expected.rootThreadID)
                try await MainActor.run {
                    guard fresh.home==target.home,!self.codexAccountInputHeld(sessionID),!self.codexAccountContinuationHeld(sessionID),
                          !self.automaticInputBusy(sessionID),self.changingGoalThreads.contains(key) else {throw AppError.message("Goal 변경 직전에 연결이나 입력 상태가 바뀌었습니다.")}
                    dispatch.started=true
                }
            }
            let result:CodexSubagentGoal
            if let requested=codexSubagentGoals.requestedChange {
                result=try await requested(target,session.cwd,expected,action,requestID,paths.directory,authorize)
            }else {result=try await codexSubagentGoals.change(target,session.cwd,expected,action,authorize)}
            let fresh=try await subagentGoalTarget(session,root:expected.rootThreadID)
            let expectedStatus:CodexGoal.Status = action == .resume ? .active:.paused
            guard dispatch.started,fresh.home==target.home,result.rootThreadID==expected.rootThreadID,result.threadID==expected.threadID,
                  result.goal?.instanceID==goal.instanceID,result.goal?.status==expectedStatus else {throw AppError.message("Goal 변경 결과가 예상 상태와 다릅니다.")}
            receipt.phase = .confirmed;receipt.result=result
            switch action {
            case .resume: receipt.detail="Goal을 재개했습니다."
            case .pause: receipt.detail=result.executionState=="idle" ? "Goal을 일시정지하고 현재 작업이 끝난 것을 확인했습니다.":"Goal은 일시정지했습니다. 현재 작업은 계속 실행 중입니다. ‘작업 종료 대기’로 기다릴 수 있습니다."
            case .wait: receipt.detail=result.executionState=="idle" ? "일시정지된 Goal의 현재 작업이 끝난 것을 확인했습니다.":"Goal은 일시정지 상태입니다. 작업 종료를 아직 확인하지 못했습니다. 다시 기다릴 수 있습니다."
            }
        } catch {
            receipt.phase=dispatch.started ? .unknown:.notStarted
            receipt.detail=dispatch.started ? "요청 결과를 확인하지 못했습니다. 자동으로 다시 보내지 않습니다. 현재 상태를 새로 확인해주세요.":error.localizedDescription
        }
        try ledger.finish(receipt)
        let summary:String
        switch action {case .pause:summary="서브에이전트 Goal 일시정지";case .resume:summary="서브에이전트 Goal 재개";case .wait:summary="서브에이전트 작업 종료 대기"}
        _ = log(AuditEvent(sessionID:sessionID,summary:summary,outcome:receipt.detail,source:"서브에이전트 관리",context:AuditContext(session:session)))
        return receipt
    }

    public func codexApprovalSubagents(sessionID: String) async throws -> [CodexSubagentRow] {
        guard let session = sessions[sessionID], let binding = session.codexApprovalBinding,
              session.agent == .codex, session.phase != .ended else { throw AppError.message("연결된 Codex 부모 대화를 선택해주세요.") }
        let target = try await questionTransport.prepareQueue(session, binding.threadID)
        try validateCodexQueueSession(session, threadID: binding.threadID)
        let activity = try await Task.detached(priority: .utility) { try CodexSubagentApprovals.readActivity(target: target, cwd: session.cwd) }.value
        try validateCodexQueueSession(session, threadID: binding.threadID)
        sessions[sessionID]?.codexActivity = activity
        publish()
        return activity.children.map { CodexSubagentRow(id: $0.id, title: $0.title, status: $0.phase.title) }
    }

    public func connectCodexApprovals(sessionID: String, threadID: String?) async throws {
        guard let session = sessions[sessionID], session.agent == .codex, session.phase != .ended,
              !automaticInputBusy(sessionID) else { throw AppError.message("세션의 입력 처리가 끝난 뒤 다시 연결해주세요.") }
        var binding: CodexApprovalBinding?
        if let threadID {
            guard !sessions.values.contains(where: { $0.id != sessionID && $0.phase != .ended && $0.codexApprovalBinding?.threadID == threadID }) else {
                throw AppError.message("이 부모 대화는 다른 세션에 연결돼 있습니다.")
            }
            let target = try await questionTransport.prepareQueue(session, threadID)
            try await codexQueue.validate(target, session.cwd)
            let choices = try await Task.detached { try CodexSubagentApprovals.roots(target: target, cwd: session.cwd) }.value
            guard let choice = choices.first(where: { $0.id == threadID }) else { throw AppError.message("실행 중인 부모 대화를 다시 선택해주세요.") }
            binding = CodexApprovalBinding(threadID: threadID, title: choice.title)
        }
        guard sessions[sessionID]?.pid == session.pid, sessions[sessionID]?.started == session.started,
              sessions[sessionID]?.cwd == session.cwd, sessions[sessionID]?.phase != .ended,
              threadID == nil || !sessions.values.contains(where: { $0.id != sessionID && $0.phase != .ended && $0.codexApprovalBinding?.threadID == threadID }),
              !automaticInputBusy(sessionID) else { throw AppError.message("원본 세션이 바뀌었습니다.") }
        try store.set("codexApprovalBinding:" + sessionID, binding.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) } ?? "")
        codexApprovalTasks.removeValue(forKey: sessionID)?.cancel()
        codexApprovalEpochs.removeValue(forKey: sessionID)
        screens.removeValue(forKey: sessionID)
        sessions[sessionID]?.codexApprovalBinding = binding
        sessions[sessionID]?.codexActivity = nil
        reconcileCodexApprovalTasks(); publish()
    }

    private func reconcileCodexApprovalTasks() {
        for id in Array(codexApprovalTasks.keys) where sessions[id]?.phase == .ended || sessions[id]?.codexApprovalBinding == nil {
            codexApprovalTasks.removeValue(forKey: id)?.cancel()
            codexApprovalEpochs.removeValue(forKey: id)
        }
        for session in sessions.values where session.phase != .ended && session.codexApprovalBinding != nil && codexApprovalTasks[session.id] == nil {
            let id = session.id, binding = session.codexApprovalBinding!, transport = questionTransport
            let epoch = UUID(); codexApprovalEpochs[id] = epoch
            codexApprovalTasks[id] = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self, !self.remoteInputStopped else { break }
                    do {
                        guard let current = self.sessions[id], current.phase != .ended,
                              current.codexApprovalBinding?.threadID == binding.threadID else { break }
                        do {
                            let holdReason=self.codexApprovalHoldReason(sessionID:id)
                            let approvalsEnabled = current.automatic && !self.snapshot.paused && holdReason == nil
                            let target = try await transport.prepareQueue(current, binding.threadID)
                            let reader = self.processReader
                            let engine = self
                            let count = try await Task.detached(priority: .utility) {
                                try await CodexSubagentApprovals.poll(target: target, cwd: current.cwd, approvalsEnabled: approvalsEnabled,
                                    observed: { activity in await engine.setCodexActivity(id, epoch: epoch, activity: activity) }, authorize: { approval in
                                    guard let records = try? reader(), records.contains(where: { $0.key == current.id && $0.agent == .codex && "/dev/" + $0.tty == current.tty }) else { return false }
                                    return await engine.reserveCodexApproval(current, threadID: binding.threadID, epoch: epoch, approval: approval)
                                }, completed: { approval, confirmed in
                                    await engine.finishCodexApproval(current, approval: approval, confirmed: confirmed)
                                })
                            }.value
                            guard self.codexApprovalEpochs[id] == epoch else { break }
                            self.setCodexApprovalStatus(id, threadID: binding.threadID, message: self.codexApprovalHoldReason(sessionID:id) ?? (!approvalsEnabled ? (self.snapshot.paused ? "전체 일시정지 중 · 상태 확인 중" : holdReason != nil ? "보류 해제 · 승인 연결 확인 중" : "자동 승인 꺼짐 · 상태 확인 중") : count.review > 0 ? "직접 확인할 요청 \(count.review)건 · 해당 서브에이전트에서 확인해주세요" : count.responded > 0 ? "승인 응답 \(count.responded)건 처리 · 자식 요청 감시 중" : "부모·서브에이전트 승인 요청 감시 중"))
                        }
                    } catch {
                        guard self.codexApprovalEpochs[id] == epoch else { break }
                        self.sessions[id]?.codexActivity = nil
                        self.publish()
                        self.setCodexApprovalStatus(id, threadID: binding.threadID, message: "연결 확인 필요: " + error.localizedDescription)
                    }
                    do { try await Task.sleep(for: .seconds(3)) } catch { break }
                }
            }
        }
    }
    private func setCodexActivity(_ id: String, epoch: UUID, activity: CodexActivitySnapshot) {
        guard codexApprovalEpochs[id] == epoch, sessions[id]?.phase != .ended,
              sessions[id]?.codexApprovalBinding?.threadID == activity.parent.id else { return }
        sessions[id]?.codexActivity = activity
        publish()
    }
    private func setCodexApprovalStatus(_ id: String, threadID: String, message: String) {
        guard sessions[id]?.codexApprovalBinding?.threadID == threadID,
              sessions[id]?.codexApprovalBinding?.status != message else { return }
        sessions[id]?.codexApprovalBinding?.status = message; publish()
    }
    private func reserveCodexApproval(_ original: AgentSession, threadID: String, epoch: UUID, approval: CodexServerApproval) -> Bool {
        guard !remoteInputStopped, !snapshot.paused, let current = sessions[original.id], current.automatic,
              !userInputHasPriority(original.id), !automaticInputBusy(original.id),
              codexApprovalHoldReason(sessionID: original.id) == nil,
              current.phase != .ended, current.pid == original.pid, current.started == original.started,
              current.tty == original.tty, current.cwd == original.cwd,
              current.codexApprovalBinding?.threadID == threadID,
              codexApprovalEpochs[original.id] == epoch,
              store.value("codexApprovalAttempt:" + approval.key) == nil else { return false }
        let event = AuditEvent(sessionID: original.id, summary: approval.summary, outcome: "서버 승인 응답 시도 · 결과 미확인",
            source: "Codex 부모·서브에이전트", context: AuditContext(session: original), request: approval.request,
            answer: approval.risk == nil ? "accept (이번 요청)" : "decline · " + approval.risk!.title)
        guard log(event) else { return false }
        do {
            try store.set("codexApprovalAttempt:" + approval.key, "attempted")
            codexServerInputReservations[original.id] = approval.key
            automaticInputSessions.insert(original.id)
            return true
        } catch { return false }
    }
    private func finishCodexApproval(_ session: AgentSession, approval: CodexServerApproval, confirmed: Bool) {
        defer {
            if codexServerInputReservations[session.id] == approval.key {
                codexServerInputReservations.removeValue(forKey: session.id)
                automaticInputSessions.remove(session.id)
                scheduleScreenApproval(session.id)
            }
        }
        _ = log(AuditEvent(sessionID: session.id, summary: approval.summary,
            outcome: confirmed ? (approval.risk == nil ? "서버 승인 확인" : "시스템 변경 거절 확인") : "서버 응답 결과 미확인 · 중복 전송하지 않음",
            source: "Codex 부모·서브에이전트", context: AuditContext(session: session), request: approval.request))
        publish()
    }

    private static func isCodexFileEdit(_ prompt:ApprovalPrompt,agent:AgentKind)->Bool {
        agent == .codex && prompt.summary.filter{!$0.isWhitespace}.hasPrefix("Wouldyouliketomakethefollowingedits?")
    }
    private static func screenApprovalRisk(_ prompt:ApprovalPrompt,agent:AgentKind,cwd:String)->SystemCommandRisk? {
        let operation=isCodexFileEdit(prompt,agent:agent) ? "write_text ":""
        return SystemCommandRisk.detect(operation+prompt.summary,cwd:cwd)
    }
    private func scheduleScreenApproval(_ id: String) {
        // The visible parent terminal owns its approvals; the server monitor
        // handles only child threads and must never race the terminal input.
        guard !hasOSPermissionWait(id) else {return}
        if systemSafetyStates[id]?.notice.isPending == true { scheduleSystemSafety(id); return }
        guard !remoteInputStopped, !automationNeedsFreshScreen.contains(id), !hasBackgroundChildren(id), claudeParents[id] == nil, !userInputHasPriority(id), !automaticInputBusy(id),
              let session = sessions[id], session.agent != .shell, session.automatic,
              session.channel.isScreen, !snapshot.paused,
              let state = screens[id], state.isCurrent, !state.attempted, state.scheduledID == nil,
              Self.screenApprovalRisk(state.prompt,agent:session.agent,cwd:session.cwd) == nil else { return }
        let scheduledRevision = revision
        let scheduledID = UUID()
        screens[id]?.scheduledID = scheduledID
        let reader = processReader
        automationRuntime.launch(id) { [weak self] epoch in
            if let retryAfter = state.retryAfter {
                let delay = retryAfter.timeIntervalSinceNow
                if delay > 0 { do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) } catch { return } }
            }
            guard !Task.isCancelled else { return }
            let live = try? await Task.detached { try reader() }.value
            guard let self else { return }
            guard !Task.isCancelled, self.automationRuntime.epoch(id) == epoch, !self.automationNeedsFreshScreen.contains(id),
                  !self.hasOSPermissionWait(id),self.revision == scheduledRevision, !self.snapshot.paused, !self.userInputHasPriority(id), !self.automaticInputBusy(id), self.sessions[id]?.automatic == true,
                  self.sessions[id] != nil,
                  self.sessions[id]?.channel == session.channel,
                  self.sessions[id]?.bridgeID == session.bridgeID,
                  self.sessions[id]?.terminalID == session.terminalID,
                  self.sessions[id]?.screenHandle == session.screenHandle,
                  let current = self.screens[id], current.isCurrent, !current.attempted,
                  current.scheduledID == scheduledID,
                  current.generation == state.generation,
                  current.prompt.requestIdentity == state.prompt.requestIdentity,
                  Self.screenApprovalRisk(current.prompt,agent:session.agent,cwd:session.cwd) == nil,
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
                defer { self.automaticInputSessions.remove(id); self.scheduleScreenApproval(id) }
                // The agent's foreground job, for hosts that can name the process they would type into.
                let job = live?.first { $0.pid == session.pid && $0.started == session.started }.map { agent in
                    (live ?? []).filter { $0.tty == agent.tty && $0.processGroup == agent.processGroup }.map(\.pid)
                } ?? []
                let target = ScreenTarget(tty: session.tty, handle: session.screenHandle, jobPIDs: job,
                    sourcePID: session.pid, sourceStarted: session.started)
                let approve = adapter.approve, raw = current.raw, kind = session.agent
                do {
                    let delivery: TerminalDelivery
                    var navigatedChild: CodexChildApprovalNavigation.Outcome?
                    if kind == .codex && CodexChildApprovalNavigation.requiresNavigation(raw) {
                        let navigation = try await CodexChildApprovalNavigation.approve(target: target, initial: raw,
                            parentThreadID: session.codexApprovalBinding?.threadID, adapter: adapter, valid: { [weak self] in
                                guard let self else { return false }
                                let records = try? await Task.detached { try reader() }.value
                                return await self.codexChildNavigationValid(session, epoch: epoch, records: records)
                            })
                        delivery = navigation.delivery; navigatedChild = navigation
                    } else {
                        delivery = try await Task.detached { try approve(target, raw, kind) }.value
                    }
                    if Task.isCancelled || self.automationRuntime.epoch(id) != epoch {
                        event.outcome = delivery == .sent ? "초기화 전 승인 입력 전달" : "초기화 전 입력 미전달 · 새 화면 확인 (\(delivery.rawValue))"
                        self.log(event); return
                    }
                    if delivery != .sent { self.retryUnsentApproval(id, dispatchID: scheduledID, generation: state.generation) }
                    if delivery == .screenChanged {
                        await self.refreshRejectedApproval(session,target:target,generation:state.generation,
                            requestIdentity:current.prompt.requestIdentity,epoch:epoch,read:adapter.validationScreens ?? adapter.screens)
                    }
                    if delivery == .sent { self.watchDeliveredApproval(id, dispatchID: scheduledID, generation: state.generation, requestIdentity: state.prompt.requestIdentity) }
                    event.outcome = delivery == .sent
                        ? navigatedChild.map { $0.approved ? "하위 요청 승인 입력 전달 · 부모 화면 복귀 확인" : "처리된 하위 요청 화면 정리 · 부모 화면 복귀 확인" } ?? "승인 입력 전달"
                        : "입력 미전달 · 새 화면 확인 (\(delivery.rawValue))"
                    self.log(event)
                } catch {
                    if error is CodexChildApprovalNavigation.Interrupted,
                       self.sessions[id]?.pid == session.pid, self.sessions[id]?.started == session.started {
                        // Navigation changes the visible request identity. A later child
                        // frame must not bypass the original uncertain-write reservation.
                        // Persist OFF so restart/resize cannot replay the possible approval.
                        do { try self.setAutomatic(id, enabled: false) }
                        catch { self.sessions[id]?.automatic = false }
                        self.sessions[id]?.pendingInTerminal = true
                        self.sessions[id]?.activityDetail = "하위 화면 조작 결과를 확인하지 못해 자동 승인을 껐습니다. 터미널을 확인한 뒤 다시 켜주세요."
                    }
                    if Task.isCancelled || self.automationRuntime.epoch(id) != epoch {
                        event.outcome = "초기화 전 입력 확인 필요: \(error.localizedDescription)"
                        self.log(event); return
                    }
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

    private func codexChildNavigationValid(_ original: AgentSession, epoch: UInt64, records: [ProcessRecord]?) -> Bool {
        guard !remoteInputStopped, !snapshot.paused, !userInputHasPriority(original.id),
              !hasOSPermissionWait(original.id), !codexAccountInputHeld(original.id),
              automationRuntime.epoch(original.id) == epoch,
              let current = sessions[original.id], current.automatic, current.phase != .ended,
              current.pid == original.pid, current.started == original.started, current.tty == original.tty,
              current.channel == original.channel, current.screenHandle == original.screenHandle,
              current.cwd == original.cwd, current.codexApprovalBinding?.threadID == original.codexApprovalBinding?.threadID else { return false }
        return records?.contains { $0.pid == original.pid && $0.started == original.started && $0.agent == .codex
            && "/dev/" + $0.tty == original.tty && $0.isForeground } == true
    }

    /// A proven non-write may mean a bulk monitor frame has lagged behind the
    /// original. Re-read only that target; never replay a sent/uncertain input.
    private func refreshRejectedApproval(_ original:AgentSession,target:ScreenTarget,generation:String,
        requestIdentity:String,epoch:UInt64,read:@escaping @Sendable([ScreenTarget]) throws->TerminalSnapshot) async {
        let id=original.id,startedAt=Date(),reader=processReader
        guard let before=remoteObservedScreens[id] else{return}
        let worker=Task.detached(priority:.userInitiated) {() throws -> (String,ScreenAnalysis)? in
            func stillOriginal() throws -> Bool {
                try Task.checkCancellation()
                return try reader().contains{$0.pid==original.pid && $0.started==original.started && $0.agent==original.agent && "/dev/"+$0.tty==original.tty && $0.isForeground}
            }
            guard try stillOriginal() else{return nil}
            let snapshot=try read([target]),frames=snapshot.screens.filter{$0.tty==original.tty}
            guard frames.count==1,!snapshot.failures.contains(where:{$0.tty==nil || $0.tty==original.tty}),try stillOriginal() else{return nil}
            let raw=frames[0].contents
            return (raw,ScreenAnalysis(raw:raw,agent:original.agent))
        }
        do {
            let value=try await withTaskCancellationHandler(operation:{try await worker.value},onCancel:{worker.cancel()})
            guard let value,!Task.isCancelled,automationRuntime.epoch(id)==epoch,!remoteInputStopped,!snapshot.paused,
                  !automationNeedsFreshScreen.contains(id),!userInputHasPriority(id),sessions[id]?.automatic==true,
                  sessions[id]?.pid==original.pid,sessions[id]?.started==original.started,sessions[id]?.tty==original.tty,
                  sessions[id]?.channel==original.channel,sessions[id]?.screenHandle==original.screenHandle,
                  screens[id]?.generation==generation,screens[id]?.prompt.requestIdentity==requestIdentity,
                  screens[id]?.attempted==false,let observed=remoteObservedScreens[id],
                  observed.observedAt<=startedAt || (observed.generation==before.generation && ScreenTextEquality.identical(observed.raw,before.raw)) else{return}
            // Unchanged monitor ticks are not newer content. They must not
            // starve a slower original read; a changed frame still wins.
            receiveScreen(sessionID:id,raw:value.0,generation:generation,source:original.channel,at:Date(),
                precomputed:value.1,screenContentsUnchanged:false)
        } catch {
            // A failed read does not authorize input. The existing non-write
            // backoff and normal monitor remain responsible for another check.
        }
    }
}
