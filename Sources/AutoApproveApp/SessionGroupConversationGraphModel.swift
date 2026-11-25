import Foundation
import Combine
import AutoApproveCore

/// One member's operating state as the graph shows it.
struct GraphMemberOperation: Equatable {
    var phase: SessionPhase?
    var input: SessionGroupMemberOperation.Input
    var unacknowledgedCount: Int
    var lastAcknowledgedAt: Date?
    var firstPendingAt: Date?
    var lastDeliveryFailure: String?
    var isDeliveryBlocked: Bool
    var terminalPhase: SessionPhase? = nil
}

extension GraphMemberOperation {
    init(_ operation: SessionGroupMemberOperation) {
        self.init(phase: operation.phase, input: operation.input, unacknowledgedCount: operation.unacknowledgedCount,
                  lastAcknowledgedAt: operation.lastAcknowledgedAt, firstPendingAt: operation.firstPendingAt,
                  lastDeliveryFailure: operation.lastDeliveryFailure, isDeliveryBlocked: operation.isDeliveryBlocked, terminalPhase: operation.terminalPhase)
    }
}

/// A node as drawn: built once per data change, compared by value so unchanged nodes are not redrawn.
struct GraphNode: Equatable, Identifiable {
    let id: UUID
    let name: String
    let provisional: Bool
    let agent: AgentKind
    let isLeader: Bool
    let depth: Int
    let status: SessionGroupGraph.NodeStatus
    let unacknowledged: Int
    let accessibilityRecent: String
    let accessibilityAll: String
    /// Records on this member's lines in the "최근" and "전체" views; they set the node size.
    let recentMessages: Int
    let allMessages: Int
    /// What the member works on, as its leader set it with the nickname.
    var role: String? = nil
    var modelLabel = ""

    func messages(_ scope: SessionGroupGraph.Scope) -> Int { scope == .recent ? recentMessages : allMessages }
    func size(_ scope: SessionGroupGraph.Scope) -> SessionGroupGraph.NodeSize { SessionGroupGraph.nodeSize(forMessages: messages(scope)) }
}

actor ConversationGraphReader {
    struct Read: @unchecked Sendable {
        let group: SessionGroup?
        let page: SessionGroupConversationPage?
        let inboxes: [UUID: SessionGroupMailbox.InboxOperation]
        let recent: [SessionGroupGraph.Edge]
        let all: [SessionGroupGraph.Edge]
        let storageChanged: Bool
    }

    private struct FileStamp: Equatable { let modified: timespec; let size: off_t; let inode: ino_t
        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.modified.tv_sec == rhs.modified.tv_sec && lhs.modified.tv_nsec == rhs.modified.tv_nsec && lhs.size == rhs.size && lhs.inode == rhs.inode
        }
    }

    private let directory: URL
    private var mailbox: SessionGroupMailbox?
    private var groupID: UUID?
    private var version: Int?
    private var stamp: FileStamp??
    private var cached: (group: SessionGroup?, page: SessionGroupConversationPage?, inboxes: [UUID: SessionGroupMailbox.InboxOperation])?

    init(directory: URL) { self.directory = directory }

    func read(groupID: UUID, force: Bool, now: Date, recomputeLines: Bool) throws -> Read? {
        if mailbox == nil { mailbox = try SessionGroupMailbox(directory: directory) }
        guard let mailbox else { return nil }
        let version = try mailbox.conversationRevision
        let stamp = fileStamp()
        let groupChanged = force || cached == nil || self.groupID != groupID || self.stamp != .some(stamp)
        let changed = groupChanged || version != self.version
        guard changed || recomputeLines else { return nil }
        if changed {
            let group = groupChanged ? try SessionGroupStore(directory: directory).load().first { $0.id == groupID } : cached?.group
            let page = group == nil ? nil : try mailbox.conversations(groupID: groupID)
            let inboxes = group == nil ? [:] : try mailbox.inboxOperations(groupID: groupID)
            cached = (group, page, inboxes)
            self.groupID = groupID
            self.version = version
            self.stamp = .some(stamp)
        }
        guard let cached else { return nil }
        let members = Set(cached.group?.members.map(\.id) ?? [])
        let records = cached.page.map(SessionGroupGraph.records) ?? []
        return Read(group: cached.group, page: cached.page, inboxes: cached.inboxes,
                    recent: SessionGroupGraph.edges(records, members: members, scope: .recent, now: now),
                    all: SessionGroupGraph.edges(records, members: members, scope: .all, now: now),
                    storageChanged: changed)
    }

    private func fileStamp() -> FileStamp? {
        var info = stat()
        guard lstat(directory.appendingPathComponent("session-groups.json").path, &info) == 0 else { return nil }
        return FileStamp(modified: info.st_mtimespec, size: info.st_size, inode: info.st_ino)
    }
}

/// The graph window's data. It checks storage once a second while the window is visible and
/// publishes only values that changed, so an unchanged check never recomputes the window.
@MainActor final class ConversationGraphModel: ObservableObject {
    struct Content: Equatable {
        var group: SessionGroup
        var page: SessionGroupConversationPage
        var operations: [UUID: GraphMemberOperation]
        var names: [UUID: SessionGroupGraph.MemberName]
        var nodes: [GraphNode]
        var recentEdges: [SessionGroupGraph.Edge]
        var allEdges: [SessionGroupGraph.Edge]

        func name(_ id: UUID) -> String { names[id]?.text ?? "이전 구성원" }
        var provisionalMembers: [UUID] { nodes.filter(\.provisional).map(\.id) }
    }

    struct SessionKey: Equatable { let id: String; let phase: SessionPhase; let title: String }

    /// Where the model reads the engine's memory. The render harness replaces these with fixed values.
    struct Sources {
        var now: @Sendable () -> Date
        var operations: @MainActor (SessionGroup, [UUID: SessionGroupMailbox.InboxOperation]) -> [UUID: GraphMemberOperation]
        /// Nickname of each connected member's session; members not connected are absent.
        var liveNicknames: @MainActor ([SessionGroupMember]) -> [UUID: String]
        var sessions: AnyPublisher<[SessionKey], Never>

        @MainActor static func live(_ engine: ApprovalEngine) -> Sources {
            Sources(
                now: { Date() },
                operations: { group, inboxes in engine.sessionGroupOperations(group, inboxes: inboxes).mapValues(GraphMemberOperation.init) },
                liveNicknames: { members in
                    let sessions = Dictionary(engine.snapshot.sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                    var result: [UUID: String] = [:]
                    for member in members {
                        if let runtime = member.runtimeID, let session = sessions[runtime], session.phase != .ended {
                            result[member.id] = session.customization?.title ?? ""
                        }
                    }
                    return result
                },
                sessions: engine.$snapshot.map { snapshot in
                    snapshot.sessions.map { SessionKey(id: $0.id, phase: $0.phase, title: $0.customization?.title ?? "") }
                }.eraseToAnyPublisher())
        }
    }

    /// The clock line at the end of the summary; isolated so its once-a-second change
    /// redraws only that line.
    @MainActor final class ReadStatus: ObservableObject {
        @Published fileprivate(set) var checkedAt: Date?
        @Published fileprivate(set) var failedSince: Date?
        @Published fileprivate(set) var failure: String?
    }

    @Published private(set) var content: Content?
    /// Set when nothing could be read yet, or the group no longer exists.
    @Published private(set) var loadError: String?
    @Published private(set) var freshEdges: Set<SessionGroupGraph.EdgeKey> = []
    let readStatus = ReadStatus()

    let groupID: UUID
    private let reader: ConversationGraphReader
    private let sources: Sources
    private var inboxes: [UUID: SessionGroupMailbox.InboxOperation] = [:]
    private var linesAt: Date?
    private var forceNext = true
    private var checking = false
    private var sessionWatch: AnyCancellable?
    private var freshClear: Task<Void, Never>?
    private let memberRuntimes = RuntimeIDs()

    private final class RuntimeIDs: @unchecked Sendable {
        private let lock = NSLock(); private var ids = Set<String>()
        var value: Set<String> { get { lock.lock(); defer { lock.unlock() }; return ids } set { lock.lock(); ids = newValue; lock.unlock() } }
    }

    init(groupID: UUID, directory: URL, sources: Sources) {
        self.groupID = groupID
        self.sources = sources
        reader = ConversationGraphReader(directory: directory)
    }

    /// Runs while the window is visible: a forced read first, then a check every second.
    func observe() async {
        forceNext = true
        let runtimes = memberRuntimes
        sessionWatch = sources.sessions
            .map { keys in let ids = runtimes.value; return keys.filter { ids.contains($0.id) } }
            .removeDuplicates()
            .debounce(for: .seconds(0.3), scheduler: RunLoop.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.recombine() } }
        defer { sessionWatch = nil }
        while !Task.isCancelled {
            await check()
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
        }
    }

    /// After a reply, a delivery, a naming request or the refresh button.
    func reload() {
        forceNext = true
        Task { await check() }
    }

    private func check() async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        let force = forceNext
        forceNext = false
        let now = sources.now()
        let tick = linesAt.map { now.timeIntervalSince($0) >= 60 } ?? true
        do {
            let result = try await reader.read(groupID: groupID, force: force, now: now, recomputeLines: tick)
            if readStatus.failure != nil { readStatus.failure = nil; readStatus.failedSince = nil }
            readStatus.checkedAt = now
            guard let result else { return }
            linesAt = now
            guard let group = result.group, let page = result.page else {
                if content != nil { content = nil }
                memberRuntimes.value = []
                loadError = "저장된 그룹을 찾을 수 없습니다."
                return
            }
            if loadError != nil { loadError = nil }
            inboxes = result.inboxes
            apply(group: group, page: page, recent: result.recent, all: result.all, newActivity: result.storageChanged)
        } catch {
            if readStatus.failure == nil { readStatus.failedSince = readStatus.checkedAt }
            readStatus.failure = error.localizedDescription
            if content == nil { loadError = error.localizedDescription }
        }
    }

    /// Session state or a nickname changed in the engine's memory: names and states only.
    private func recombine() {
        guard let content else { return }
        apply(group: content.group, page: content.page, recent: content.recentEdges, all: content.allEdges, newActivity: false)
    }

    private func apply(group: SessionGroup, page: SessionGroupConversationPage, recent: [SessionGroupGraph.Edge],
                       all: [SessionGroupGraph.Edge], newActivity: Bool) {
        memberRuntimes.value = Set(group.members.compactMap(\.runtimeID))
        let operations = sources.operations(group, inboxes)
        let names = SessionGroupGraph.names(group: group, liveNicknames: sources.liveNicknames(group.members))
        let plainNames = names.mapValues(\.text)
        let nodes = group.treeOrder.map { entry -> GraphNode in
            let member = entry.member
            let operation = operations[member.id]
            let status = SessionGroupGraph.status(phase: operation?.terminalPhase ?? operation?.phase, blocked: operation?.isDeliveryBlocked == true)
            return GraphNode(id: member.id, name: plainNames[member.id] ?? member.title, provisional: names[member.id]?.provisional ?? true,
                             agent: member.agent, isLeader: group.isLeader(member.id), depth: entry.depth, status: status,
                             unacknowledged: operation?.unacknowledgedCount ?? 0,
                             accessibilityRecent: SessionGroupGraph.accessibilityValue(member: member.id, status: status, edges: recent, names: plainNames),
                             accessibilityAll: SessionGroupGraph.accessibilityValue(member: member.id, status: status, edges: all, names: plainNames),
                             recentMessages: SessionGroupGraph.messageCount(member: member.id, edges: recent),
                             allMessages: SessionGroupGraph.messageCount(member: member.id, edges: all),
                             role: member.role)
        }
        let next = Content(group: group, page: page, operations: operations, names: names, nodes: nodes, recentEdges: recent, allEdges: all)
        guard next != content else { return }
        if newActivity, let previous = content {
            let fresh = SessionGroupGraph.freshKeys(previous: previous.allEdges, current: all)
            if !fresh.isEmpty { highlight(fresh) }
        }
        content = next
    }

    /// New lines get an accent outline for three seconds.
    private func highlight(_ keys: Set<SessionGroupGraph.EdgeKey>) {
        freshEdges = keys
        freshClear?.cancel()
        freshClear = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            self?.freshEdges = []
        }
    }
}
