import Foundation

public struct SessionGroupIdentityRefresh: Equatable, Sendable {
    public let conversationID: String
    public let mergedMemberID: UUID?
    public let changed: Bool
}
import Darwin

public enum SessionGroupTerminalStatus {
    public static func freshConversationID(before: String, after: String, agent: AgentKind) -> String? {
        if agent == .codex { return CodexStatusIdentity(screen: before).freshThread(in: after) }
        guard agent == .claude, after.contains("Version:"), after.contains("Session ID:") else { return nil }
        let previous = conversationIDs(before), current = conversationIDs(after)
        guard let id = current.last, current.count > previous.count || id != previous.last else { return nil }
        return id
    }
    /// Read only the labelled ID in a CLI status card, never arbitrary UUIDs in chat.
    private static func conversationIDs(_ screen: String) -> [String] {
        let text = PromptDetector.normalizedLines(screen).joined(separator: "\n")
        let pattern = #"(?im)^\s*[│┃|]?\s*Session(?:\s+ID)?\s*:\s*([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let range = Range(match.range(at: 1), in: text), let uuid = UUID(uuidString: String(text[range])) else { return nil }
            return uuid.uuidString.lowercased()
        }
    }
}

/// A saved collaboration group identifies conversations, not processes or projects.
public struct SessionGroupMember: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var agent: AgentKind
    public var title: String
    public var cwd: String
    public var conversationID: String
    public var providerHome: String?
    /// A live process identity helps present an unresolved member, never a replacement for a conversation ID.
    public var runtimeID: String? = nil
    public var tabShell: SessionGroupTabShell?
    /// The member that directs this one. Nil places a member directly under the leader.
    public var parentMemberID: UUID? = nil
    /// One line on what this member works on, set with its nickname through set_group_member_title.
    public var role: String? = nil

    public init(id: UUID = UUID(), agent: AgentKind, title: String, cwd: String,
                conversationID: String, providerHome: String? = nil) {
        self.id = id; self.agent = agent; self.title = title; self.cwd = cwd
        self.conversationID = conversationID; self.providerHome = providerHome
    }

    /// Updating a terminal binding never changes the member's place in its group.
    public func updatingConnection(from live: SessionGroupLiveSession) -> SessionGroupMember {
        var result = live.member
        result.id = id; result.parentMemberID = parentMemberID; result.role = role
        return result
    }
}

public struct SessionGroupTreeEntry: Identifiable, Equatable {
    public var member: SessionGroupMember
    public var depth: Int
    public var id: UUID { member.id }
}

public struct SessionGroup: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var members: [SessionGroupMember]
    /// Order supplies a stable default report recipient. Every leader has the same authority.
    public private(set) var leaderMemberIDs: [UUID]
    public var leaderMemberID: UUID? {
        get { leaderMemberIDs.first }
        set { leaderMemberIDs = newValue.map { [$0] } ?? [] }
    }

    public init(id: UUID = UUID(), name: String, members: [SessionGroupMember] = [], leaderMemberID: UUID? = nil) {
        self.id = id; self.name = name; self.members = members
        self.leaderMemberIDs = leaderMemberID.map { [$0] } ?? []
    }

    private enum CodingKeys: String, CodingKey { case id, name, members, leaderMemberID, leaderMemberIDs }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        members = try values.decode([SessionGroupMember].self, forKey: .members)
        let legacy = try values.decodeIfPresent(UUID.self, forKey: .leaderMemberID)
        leaderMemberIDs = try values.decodeIfPresent([UUID].self, forKey: .leaderMemberIDs) ?? legacy.map { [$0] } ?? []
        if let legacy, leaderMemberIDs.first != legacy {
            throw DecodingError.dataCorruptedError(forKey: .leaderMemberIDs, in: values, debugDescription: "Inconsistent group leaders")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(name, forKey: .name)
        try values.encode(members, forKey: .members)
        try values.encodeIfPresent(leaderMemberID, forKey: .leaderMemberID)
        try values.encode(leaderMemberIDs, forKey: .leaderMemberIDs)
    }

    /// Learning an OS shell receipt changes neither group membership nor its permissions.
    func sameMembership(as other: Self) -> Bool {
        var lhs = self, rhs = other
        for i in lhs.members.indices { lhs.members[i].tabShell = nil }
        for i in rhs.members.indices { rhs.members[i].tabShell = nil }
        return lhs == rhs
    }

    public func isLeader(_ id: UUID) -> Bool { leaderMemberIDs.contains(id) }

    /// All leaders share direction of the top level. Lower tiers retain their own supervisors.
    public func canDirect(_ caller: UUID, worker: UUID) -> Bool {
        guard let parent = parentID(of: worker) else { return false }
        return caller == parent || (isLeader(caller) && isLeader(parent))
    }

    /// The member that assigns work to `memberID` and receives its reports.
    public func parentID(of memberID: UUID) -> UUID? {
        guard let leader = leaderMemberID, !isLeader(memberID),
              let member = members.first(where: { $0.id == memberID }) else { return nil }
        return member.parentMemberID ?? leader
    }

    public func children(of memberID: UUID) -> [SessionGroupMember] {
        members.filter { $0.id != memberID && parentID(of: $0.id) == memberID }
    }

    /// Leader first, then each member under its parent. Without a leader, the saved order.
    public var treeOrder: [SessionGroupTreeEntry] {
        guard !leaderMemberIDs.isEmpty else {
            return members.map { SessionGroupTreeEntry(member: $0, depth: 0) }
        }
        var result: [SessionGroupTreeEntry] = []
        var visited = Set<UUID>()
        func visit(_ member: SessionGroupMember, _ depth: Int) {
            guard visited.insert(member.id).inserted else { return }
            result.append(SessionGroupTreeEntry(member: member, depth: depth))
            for child in children(of: member.id) { visit(child, depth + 1) }
        }
        for id in leaderMemberIDs { if let root = members.first(where: { $0.id == id }) { visit(root, 0) } }
        // A validated group has no unreachable member; keep any anyway so nothing disappears from view.
        for member in members where !visited.contains(member.id) { result.append(SessionGroupTreeEntry(member: member, depth: 1)) }
        return result
    }

    /// Members that can direct `memberID` without creating a cycle: never itself or one of its descendants.
    public func parentCandidates(for memberID: UUID) -> [SessionGroupMember] {
        guard leaderMemberID != nil, !isLeader(memberID) else { return [] }
        var descendants = Set<UUID>([memberID]), queue = [memberID]
        while let next = queue.popLast() {
            for child in children(of: next) where descendants.insert(child.id).inserted { queue.append(child.id) }
        }
        return members.filter { !descendants.contains($0.id) }
    }

    /// The new leader leaves its parent; every other link stays, so the tree remains acyclic.
    public func settingLeader(_ memberID: UUID) -> SessionGroup {
        var result = self
        guard members.contains(where: { $0.id == memberID }) else { return result }
        result.leaderMemberID = memberID
        for index in result.members.indices where result.members[index].id == memberID {
            result.members[index].parentMemberID = nil
        }
        return result
    }

    public func addingLeader(_ id: UUID) -> Self {
        guard !isLeader(id), let index = members.firstIndex(where: { $0.id == id }) else { return self }
        var result = self
        result.leaderMemberIDs.append(id)
        result.members[index].parentMemberID = nil
        return result
    }

    public func removingLeader(_ id: UUID) -> Self {
        guard isLeader(id) else { return self }
        var result = self
        result.leaderMemberIDs.removeAll { $0 == id }
        for i in result.members.indices where result.leaderMemberIDs.isEmpty || result.members[i].parentMemberID == id {
            result.members[i].parentMemberID = nil
        }
        return result
    }

    /// Setting the leader as a parent stores nil, which already means "directly under the leader".
    public func settingParent(_ parentID: UUID, for memberID: UUID) -> SessionGroup {
        var result = self
        guard parentCandidates(for: memberID).contains(where: { $0.id == parentID }) else { return result }
        for index in result.members.indices where result.members[index].id == memberID {
            result.members[index].parentMemberID = parentID == leaderMemberID ? nil : parentID
        }
        return result
    }

    /// A removed member's reports move to its own parent; removing the leader dissolves the tree.
    public func removing(_ memberID: UUID) -> SessionGroup {
        var result = self
        if isLeader(memberID) {
            result = removingLeader(memberID)
        } else {
            let parent = members.first { $0.id == memberID }?.parentMemberID
            for index in result.members.indices where result.members[index].parentMemberID == memberID {
                result.members[index].parentMemberID = parent
            }
        }
        result.members.removeAll { $0.id == memberID }
        return result
    }

    public func validated() throws -> Self {
        var result = self
        result.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.name.isEmpty, result.name.count <= 80,
              !result.name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              members.count <= 128, Set(members.map(\.id)).count == members.count else {
            throw AppError.message("그룹 이름과 구성원 목록을 확인해주세요.")
        }
        var identities = Set<String>(), runtimes = Set<String>()
        for index in result.members.indices {
            var member = result.members[index]
            guard member.agent != .shell, member.title.count <= 256,
                  !member.title.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  member.cwd.hasPrefix("/"), member.cwd.utf8.count <= 4096,
                  !member.cwd.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  member.providerHome.map({ $0.hasPrefix("/") && $0.utf8.count <= 4096 && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }) ?? true,
                  member.runtimeID.map({ !$0.isEmpty && $0.utf8.count <= 512 && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }) ?? true,
                  member.conversationID.isEmpty || UUID(uuidString: member.conversationID) != nil else {
                throw AppError.message("구성원의 종류, 경로와 확인된 대화 ID를 확인해주세요.")
            }
            if let uuid = UUID(uuidString: member.conversationID) {
                member.conversationID = uuid.uuidString.lowercased()
                let identity = member.agent.rawValue + "\n" + (member.providerHome ?? "") + "\n" + member.conversationID
                guard identities.insert(identity).inserted else { throw AppError.message("같은 대화가 그룹에 중복되어 있습니다.") }
            }
            if let runtime = member.runtimeID, !runtimes.insert(runtime).inserted {
                throw AppError.message("같은 실행 세션이 그룹에 중복되어 있습니다.")
            }
            result.members[index] = member
        }
        try result.validateTree()
        return result
    }

    /// Every member must reach the leader through existing parents, without a cycle.
    private func validateTree() throws {
        let invalid = AppError.message("그룹장과 상위 구성원 연결을 확인해주세요.")
        guard let leader = leaderMemberID else {
            guard members.allSatisfy({ $0.parentMemberID == nil }) else { throw invalid }
            return
        }
        let byID = Dictionary(uniqueKeysWithValues: members.map { ($0.id, $0) })
        guard Set(leaderMemberIDs).count == leaderMemberIDs.count,
              leaderMemberIDs.allSatisfy({ byID[$0] != nil && byID[$0]?.parentMemberID == nil }) else { throw invalid }
        for member in members where !isLeader(member.id) {
            var seen: Set<UUID> = [member.id], current = member
            while let parent = current.parentMemberID, parent != leader {
                guard seen.insert(parent).inserted, let next = byID[parent] else { throw invalid }
                current = next
            }
        }
    }
}

public struct SessionGroupTabShell: Codable, Equatable, Sendable {
    let host: TerminalKind
    let tty: String
    let shellRuntime: String

    var terminalSessionID: UUID? = nil

    func identifies(_ other: Self?) -> Bool {
        guard let other, host == other.host else { return false }
        if let terminalSessionID, let observed = other.terminalSessionID { return terminalSessionID == observed }
        return tty == other.tty && shellRuntime == other.shellRuntime
    }

    static func observe(_ session: AgentSession, process: ProcessRecord, records: [Int32: ProcessRecord], environment: [String: String]? = nil) -> Self? {
        guard session.agent != .shell, [.terminal, .iterm].contains(session.terminal),
              process.key == session.id, "/dev/" + process.tty == session.tty,
              let parent = records[process.parent], parent.tty == process.tty,
              SessionExitRecovery.isShell(parent) else { return nil }
        let raw = session.terminal == .iterm ? environment?["ITERM_SESSION_ID"]?.components(separatedBy: ":").last : environment?["TERM_SESSION_ID"]
        return Self(host: session.terminal, tty: session.tty, shellRuntime: parent.key, terminalSessionID: raw.flatMap(UUID.init(uuidString:)))
    }
}

/// Current observation, kept separate from the persisted group entry.
public struct SessionGroupLiveSession: Identifiable, Equatable {
    public var session: AgentSession
    public var conversationID: String?
    public var providerHome: String?
    public var messagingName: String?
    var tabShell: SessionGroupTabShell?
    var codexIdentityFromMCP = false
    var claudeRegisteredStatus: String?
    public var id: String { session.id }
    public init(session: AgentSession, conversationID: String?, providerHome: String?, messagingName: String? = nil) {
        self.session = session; self.conversationID = conversationID; self.providerHome = providerHome; self.messagingName = messagingName
    }
    public var member: SessionGroupMember {
        let title = String(session.displayedTerminalTitle.components(separatedBy: .newlines).joined(separator: " ")
            .unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(String.init).joined().prefix(256))
        var value = SessionGroupMember(agent: session.agent, title: title,
            cwd: session.cwd, conversationID: conversationID ?? "", providerHome: providerHome)
        value.tabShell = tabShell
        value.runtimeID = session.id
        return value
    }
}

public struct SessionGroupMemberOperation: Equatable {
    public enum Input: Equatable {
        case unverified
        case idle
        case deferred(String)
    }

    public let phase: SessionPhase?
    public let input: Input
    public let unacknowledgedCount: Int
    public let lastAcknowledgedAt: Date?
    public let firstPendingAt: Date?
    public let lastDeliveryFailure: String?
    public let isDeliveryBlocked: Bool
}

public enum SessionGroupMatching {
    public static func replacement(_ member: SessionGroupMember, in live: [SessionGroupLiveSession], selected: String?) -> SessionGroupLiveSession? {
        let home = member.providerHome ?? (member.agent == .claude ? TerminalProfileGroup.normalizedHome(nil, agent: "claude") : nil)
        guard member.agent != .shell, let home, let previous = UUID(uuidString: member.conversationID),
              !live.contains(where: { $0.id == member.runtimeID || ($0.session.agent == member.agent && $0.providerHome == home &&
                  $0.conversationID.flatMap(UUID.init(uuidString:)) == previous) }) else { return nil }
        let matches = live.filter { row in
            guard row.session.agent == member.agent, row.session.phase != .ended, row.session.cwd == member.cwd,
                  row.providerHome == home else { return false }
            if member.agent == .claude, let selected {
                return row.id == selected && row.conversationID.flatMap(UUID.init(uuidString:)) != nil
            }
            return [.terminal, .iterm].contains(row.session.terminal) &&
                (selected.map { row.id == $0 } ?? (member.tabShell?.identifies(row.tabShell) == true))
        }
        return matches.count == 1 ? matches[0] : nil
    }

    package static func refreshedClaude(_ groups: [SessionGroup], live: [SessionGroupLiveSession]) -> [SessionGroup] {
        groups.map { group in
            var updated = group
            for (index, member) in group.members.enumerated() where member.agent == .claude || member.agent == .agy {
                if let resumed = match(member, in: live), resumed.id != member.runtimeID,
                   (member.providerHome != nil || (member.agent == .claude && resumed.providerHome != nil)), UUID(uuidString: member.conversationID) != nil,
                   !live.contains(where: { $0.id == member.runtimeID && $0.session.phase != .ended }),
                   !group.members.contains(where: { $0.id != member.id && $0.agent == member.agent &&
                       ($0.runtimeID == resumed.id || (UUID(uuidString: $0.conversationID) == UUID(uuidString: member.conversationID) &&
                           ($0.providerHome == nil || $0.providerHome == resumed.providerHome))) }) {
                    updated.members[index].providerHome = resumed.providerHome ?? member.providerHome
                    updated.members[index].cwd = resumed.session.cwd
                    updated.members[index].runtimeID = resumed.id
                    updated.members[index].tabShell = resumed.tabShell
                    continue
                }
                let old = UUID(uuidString: member.conversationID)
                guard old != nil || (member.agent == .agy && member.conversationID.isEmpty),
                      let runtime = member.runtimeID,
                      let endpoint = connection(member, in: live), endpoint.id == runtime,
                      let fresh = endpoint.conversationID.flatMap(UUID.init(uuidString:)), fresh != old,
                      member.providerHome == nil || member.providerHome == endpoint.providerHome,
                      !live.contains(where: { other in
                          other.id != runtime && other.session.agent == member.agent && other.providerHome == endpoint.providerHome &&
                          other.conversationID.flatMap(UUID.init(uuidString:)).map { [old, fresh].contains($0) } == true
                      }),
                      !group.members.contains(where: {
                          $0.id != member.id && $0.agent == member.agent &&
                          ($0.runtimeID == runtime || (UUID(uuidString: $0.conversationID) == fresh &&
                              ($0.providerHome == nil || $0.providerHome == endpoint.providerHome)))
                      }) else { continue }
                updated.members[index].conversationID = fresh.uuidString.lowercased()
                updated.members[index].providerHome = endpoint.providerHome ?? member.providerHome
            }
            return updated
        }
    }

    /// Process connectivity is separate from conversation identity. This is only
    /// for presentation and explicit identity refresh, never task delivery.
    public static func connection(_ member: SessionGroupMember, in live: [SessionGroupLiveSession]) -> SessionGroupLiveSession? {
        let candidates = live.filter {
            $0.id == member.runtimeID && $0.session.agent == member.agent &&
            $0.session.phase != .ended && $0.session.cwd == member.cwd &&
            (member.providerHome == nil || $0.providerHome == nil || member.providerHome == $0.providerHome)
        }
        if candidates.count == 1 { return candidates[0] }
        guard candidates.isEmpty else { return nil }
        return match(member, in: live)
    }

    public static func match(_ member: SessionGroupMember, in live: [SessionGroupLiveSession]) -> SessionGroupLiveSession? {
        let matches = live.filter { observation in
            guard observation.session.agent == member.agent, observation.session.phase != .ended else { return false }
            if member.agent == .codex || member.agent == .agy, let id = UUID(uuidString: member.conversationID) {
                return id == observation.conversationID.flatMap(UUID.init(uuidString:)) &&
                    (member.providerHome == nil || member.providerHome == observation.providerHome)
            }
            if member.conversationID.isEmpty {
                return member.runtimeID == observation.id && member.cwd == observation.session.cwd
            }
            if member.agent == .claude, let id = UUID(uuidString: member.conversationID), let observedHome = observation.providerHome,
               id == observation.conversationID.flatMap(UUID.init(uuidString:)),
               TerminalProfileGroup.normalizedHome(member.providerHome, agent: "claude") ==
                   TerminalProfileGroup.normalizedHome(observedHome, agent: "claude") { return true }
            if member.providerHome == nil {
                return member.runtimeID == observation.id && member.cwd == observation.session.cwd &&
                    UUID(uuidString: member.conversationID) == observation.conversationID.flatMap(UUID.init(uuidString:))
            }
            guard let home = member.providerHome, let observedHome = observation.providerHome,
                  let id = UUID(uuidString: member.conversationID),
                  let observedID = observation.conversationID.flatMap(UUID.init(uuidString:)) else { return false }
            return id == observedID && home == observedHome && member.cwd == observation.session.cwd
        }
        return matches.count == 1 ? matches[0] : nil
    }
}

/// Separate from session profiles; never treats a damaged file as an empty list.
public struct SessionGroupStore {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }
    private var file: URL { directory.appendingPathComponent("session-groups.json") }

    public func load() throws -> [SessionGroup] {
        try TerminalProfileStore(directory: directory).prepare()
        var info = stat()
        if lstat(file.path, &info) != 0 {
            guard errno == ENOENT else { throw AppError.message("세션 그룹 파일을 확인하지 못했습니다.") }
            return []
        }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid() else {
            throw AppError.message("세션 그룹 파일의 소유자와 형식을 확인해주세요.")
        }
        let data = try TerminalProfileStore.read(file)
        let groups: [SessionGroup]
        do { groups = try JSONDecoder().decode([SessionGroup].self, from: data).map { try $0.validated() } }
        catch { throw AppError.message("세션 그룹 파일을 읽지 못했습니다. 기존 파일을 유지합니다.") }
        guard groups.count <= 200, Set(groups.map(\.id)).count == groups.count else {
            throw AppError.message("세션 그룹 파일의 그룹 수 또는 ID를 확인해주세요.")
        }
        return groups
    }

    public func save(_ groups: [SessionGroup], expected: [SessionGroup]? = nil) throws {
        // Read first so a corrupt or replaced file cannot silently be overwritten.
        let current = try load()
        if let expected, current != expected {
            throw AppError.message("세션 그룹이 다른 곳에서 변경되었습니다. 새로고침한 뒤 다시 시도해주세요.")
        }
        let values = try groups.map { try $0.validated() }
        guard values.count <= 200, Set(values.map(\.id)).count == values.count else {
            throw AppError.message("세션 그룹의 수 또는 ID를 확인해주세요.")
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(values)
        guard data.count <= TerminalProfileStore.maximumBytes else { throw AppError.message("세션 그룹 파일이 너무 큽니다.") }
        try TerminalProfileStore.write(data, to: file)
    }
}

/// How a live session takes part in a session group, shown in session lists.
public struct SessionGroupBadge: Codable, Equatable, Sendable {
    public enum Role: String, Codable, Sendable {
        case leader
        case member
        /// The group has no leader, so its members are not ranked.
        case unranked
    }
    public enum TaskState: String, Codable, Sendable {
        case working
        /// The worker stopped on a choice question its parent has to answer.
        case question
        /// The worker stopped on a permission prompt delegated to its parent.
        case approval
        /// The worker finished and its report has not reached the parent yet.
        case reporting
    }

    public var groupID: UUID
    public var groupName: String
    public var memberID: UUID
    public var role: Role
    public var depth: Int
    public var parentTitle: String?
    /// The member that directs this one, for nesting rows in session lists.
    public var parentMemberID: UUID?
    public var childCount: Int
    /// Other groups this session also belongs to; only one badge is shown.
    public var otherGroupCount: Int
    public var task: TaskState?
    /// Reports and questions from this member's workers that have not reached it yet.
    public var pendingReports: Int

    public init(groupID: UUID, groupName: String, memberID: UUID, role: Role, depth: Int = 0, parentTitle: String? = nil,
                parentMemberID: UUID? = nil, childCount: Int = 0, otherGroupCount: Int = 0, task: TaskState? = nil, pendingReports: Int = 0) {
        self.groupID = groupID; self.groupName = groupName; self.memberID = memberID; self.role = role; self.depth = depth
        self.parentTitle = parentTitle; self.parentMemberID = parentMemberID; self.childCount = childCount; self.otherGroupCount = otherGroupCount
        self.task = task; self.pendingReports = pendingReports
    }

    /// One badge per live session. A session in several groups shows the group where it leads,
    /// then where it works for a parent, then a group without a leader.
    public static func badges(groups: [SessionGroup], live: [SessionGroupLiveSession]) -> [String: SessionGroupBadge] {
        var candidates: [String: [SessionGroupBadge]] = [:]
        for group in groups {
            let depths = Dictionary(group.treeOrder.map { ($0.member.id, $0.depth) }, uniquingKeysWith: { first, _ in first })
            for member in group.members {
                // List membership follows the original process while its conversation
                // identity is being refreshed. Task delivery still uses strict matching.
                guard let session = SessionGroupMatching.connection(member, in: live) else { continue }
                let role: Role = group.leaderMemberID == nil ? .unranked : group.isLeader(member.id) ? .leader : .member
                let parent = group.parentID(of: member.id).flatMap { id in group.members.first { $0.id == id } }
                candidates[session.id, default: []].append(SessionGroupBadge(
                    groupID: group.id, groupName: group.name, memberID: member.id, role: role,
                    depth: role == .unranked ? 0 : depths[member.id] ?? 0, parentTitle: parent?.title,
                    parentMemberID: role == .unranked ? nil : parent?.id,
                    childCount: role == .unranked ? 0 : group.members.filter { group.canDirect(member.id, worker: $0.id) }.count))
            }
        }
        let rank: [Role: Int] = [.leader: 0, .member: 1, .unranked: 2]
        return candidates.compactMapValues { values in
            guard var best = values.sorted(by: {
                rank[$0.role]! != rank[$1.role]! ? rank[$0.role]! < rank[$1.role]!
                    : $0.groupName.localizedStandardCompare($1.groupName) == .orderedAscending
            }).first else { return nil }
            best.otherGroupCount = values.count - 1
            return best
        }
    }
}

/// Session list rows arranged by group: each group holds its leader and members as a tree,
/// and sessions outside every group stay a flat, reorderable list.
public struct SessionListTree: Equatable {
    public struct Node: Identifiable, Equatable {
        public var session: AgentSession
        public var children: [Node]
        public var id: String { session.id }
        /// Expansion key: one member of one group.
        public var key: String { session.sessionGroup.map { "member:\($0.groupID.uuidString):\($0.memberID.uuidString)" } ?? session.id }
    }
    public struct Group: Identifiable, Equatable {
        public var groupID: UUID
        public var name: String
        public var hasLeader: Bool
        public var roots: [Node]
        public var sessionCount: Int
        /// Members waiting for a person or a parent, so a collapsed group still shows them.
        public var attentionCount: Int
        public var id: String { "group:" + groupID.uuidString }
    }
    public var groups: [Group]
    public var ungrouped: [AgentSession]

    /// Keeps the given order. A member whose parent is not in the list becomes a root of its group,
    /// with the leader first.
    public static func build(_ sessions: [AgentSession]) -> SessionListTree {
        var order: [UUID] = [], grouped: [UUID: [AgentSession]] = [:], ungrouped: [AgentSession] = []
        for session in sessions {
            guard let badge = session.sessionGroup else { ungrouped.append(session); continue }
            if grouped[badge.groupID] == nil { order.append(badge.groupID) }
            grouped[badge.groupID, default: []].append(session)
        }
        let groups = order.map { id -> Group in
            let members = grouped[id] ?? []
            let present = Set(members.compactMap { $0.sessionGroup?.memberID })
            var children: [UUID: [AgentSession]] = [:], roots: [AgentSession] = []
            for session in members {
                if let parent = session.sessionGroup?.parentMemberID, present.contains(parent), parent != session.sessionGroup?.memberID {
                    children[parent, default: []].append(session)
                } else { roots.append(session) }
            }
            roots = roots.filter { $0.sessionGroup?.role == .leader } + roots.filter { $0.sessionGroup?.role != .leader }
            var visited = Set<UUID>()
            // Each member appears once, even when saved parents form a loop.
            func node(_ session: AgentSession) -> Node? {
                guard let member = session.sessionGroup?.memberID, visited.insert(member).inserted else { return nil }
                return Node(session: session, children: (children[member] ?? []).compactMap(node))
            }
            var built = roots.compactMap(node)
            // A broken parent chain must not hide a session: anything not reached is added as a root.
            for session in members where !visited.contains(session.sessionGroup!.memberID) { if let root = node(session) { built.append(root) } }
            let first = members[0].sessionGroup!
            return Group(groupID: id, name: first.groupName, hasLeader: first.role != .unranked, roots: built, sessionCount: members.count,
                         attentionCount: members.filter { $0.needsReview || [.question, .approval].contains($0.sessionGroup?.task) }.count)
        }
        return SessionListTree(groups: groups, ungrouped: ungrouped)
    }
}
