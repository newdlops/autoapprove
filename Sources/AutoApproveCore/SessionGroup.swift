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
    public var parentMemberID: UUID? = nil
    public var assignedParentIDs: [UUID]?
    /// One line on what this member works on, set with its nickname through set_group_member_title.
    public var role: String? = nil
    public var nickname: String? = nil

    public var diagnosticLabel: String {
        let name = [nickname, title].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
        let identity = "\(agent.title) · \(id.uuidString.prefix(8))"
        return name.map { "\($0) (\(identity))" } ?? identity
    }

    public init(id: UUID = UUID(), agent: AgentKind, title: String, cwd: String,
                conversationID: String, providerHome: String? = nil) {
        self.id = id; self.agent = agent; self.title = title; self.cwd = cwd
        self.conversationID = conversationID; self.providerHome = providerHome
    }

    public func updatingConnection(from live: SessionGroupLiveSession) -> SessionGroupMember {
        var result = live.member
        result.assignedParentIDs = assignedParentIDs
        result.id = id; result.parentMemberID = parentMemberID; result.role = role; result.nickname = nickname
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
    public var parentGroupIDs: [UUID] = []
    public private(set) var leaderMemberIDs: [UUID]
    public var leaderMemberID: UUID? {
        get { leaderMemberIDs.first }
        set { leaderMemberIDs = newValue.map { [$0] } ?? [] }
    }

    public init(id: UUID = UUID(), name: String, members: [SessionGroupMember] = [], leaderMemberID: UUID? = nil) {
        self.id = id; self.name = name; self.members = members
        self.leaderMemberIDs = leaderMemberID.map { [$0] } ?? []
    }

    private enum CodingKeys: String, CodingKey { case id, name, members, leaderMemberID, leaderMemberIDs, parentGroupIDs }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        members = try values.decode([SessionGroupMember].self, forKey: .members)
        parentGroupIDs = try values.decodeIfPresent([UUID].self, forKey: .parentGroupIDs) ?? []
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
        if !parentGroupIDs.isEmpty { try values.encode(parentGroupIDs, forKey: .parentGroupIDs) }
    }

    /// Learning an OS shell receipt changes neither group membership nor its permissions.
    func sameMembership(as other: Self) -> Bool {
        var lhs = self, rhs = other
        for i in lhs.members.indices { lhs.members[i].tabShell = nil }
        for i in rhs.members.indices { rhs.members[i].tabShell = nil }
        return lhs == rhs
    }

    public func isLeader(_ id: UUID) -> Bool { leaderMemberIDs.contains(id) }

    public func canDirect(_ caller: UUID, worker: UUID) -> Bool {
        guard caller != worker, let parent = parentID(of: worker) else { return false }
        if parentIDs(of: worker).contains(caller) { return true }
        if members.first(where: { $0.id == worker })?.assignedParentIDs != nil { return false }
        return !isLeader(worker) && isLeader(caller) && parentID(of: caller) == nil
            && isLeader(parent) && parentID(of: parent) == nil
    }

    package func canManage(_ caller: UUID, member target: UUID) -> Bool {
        guard isLeader(caller) else { return false }
        if caller == target { return true }
        if !members.contains(where: { $0.assignedParentIDs != nil || (isLeader($0.id) && $0.parentMemberID != nil) }) { return true }
        if canDirect(caller, worker: target) { return true }
        return reaches(caller, member: target)
    }

    public func reaches(_ ancestor: UUID, member: UUID) -> Bool {
        var pending = [member], visited = Set<UUID>()
        while let id = pending.popLast() {
            guard visited.insert(id).inserted else { continue }
            if id == ancestor { return true }
            pending.append(contentsOf: parentIDs(of: id).filter { !visited.contains($0) })
        }
        return false
    }

    public func parentIDs(of memberID: UUID) -> [UUID] {
        guard let member = members.first(where: { $0.id == memberID }) else { return [] }
        if let explicit = member.assignedParentIDs { return explicit }
        return (member.parentMemberID ?? (isLeader(memberID) ? nil : leaderMemberID)).map { [$0] } ?? []
    }

    package func canManageGoal(_ leader: UUID, member: UUID) -> Bool {
        isLeader(leader) && (canDirect(leader, worker: member) || goalReviewLeaders(for: member).contains(leader))
    }

    func goalReviewLeaders(for member: UUID) -> Set<UUID> {
        var pending = parentIDs(of: member), visited: Set<UUID> = [member], leaders = Set<UUID>()
        while let id = pending.popLast() {
            guard visited.insert(id).inserted else { continue }
            if isLeader(id) { leaders.insert(id) }
            else { pending.append(contentsOf: parentIDs(of: id)) }
        }
        if leaders.isEmpty { return isLeader(member) ? [member] : Set(leaderMemberIDs.filter { canManage($0, member: member) }) }
        return leaders
    }

    public func parentID(of memberID: UUID) -> UUID? { parentIDs(of: memberID).first }

    public func children(of memberID: UUID) -> [SessionGroupMember] {
        members.filter { parentIDs(of: $0.id).contains(memberID) }
    }

    public func linkingParent(_ parent: UUID, to child: UUID, connected: Bool) throws -> Self {
        guard parent != child, let index = members.firstIndex(where: { $0.id == child }),
              members.contains(where: { $0.id == parent }) else { throw AppError.message("서로 다른 두 그룹 구성원을 선택해주세요.") }
        var parents = parentIDs(of: child)
        guard parents.contains(parent) != connected else { return self }
        if connected { parents.append(parent) } else { parents.removeAll { $0 == parent } }
        var result = self
        result.members[index].parentMemberID = nil
        result.members[index].assignedParentIDs = parents
        return result
    }

    public static func downstream(of source: UUID, in groups: [Self]) -> Set<UUID> {
        var result = Set<UUID>(), pending = [source]
        while let current = pending.popLast() {
            guard result.insert(current).inserted else { continue }
            pending.append(contentsOf: groups.filter { $0.parentGroupIDs.contains(current) }.map(\.id))
        }
        return result
    }

    public func hasGroupAuthority(_ member: UUID) -> Bool {
        guard isLeader(member) else { return false }
        if parentIDs(of: member).isEmpty { return true }
        var visited = Set<UUID>(), pending = parentIDs(of: member)
        while let parent = pending.popLast() {
            guard visited.insert(parent).inserted else { continue }
            if !reaches(member, member: parent) { return false }
            pending.append(contentsOf: parentIDs(of: parent))
        }
        return true
    }

    public func linkingGroupParent(_ parent: UUID, connected: Bool) throws -> Self {
        guard parent != id else { throw AppError.message("서로 다른 두 그룹을 선택해주세요.") }
        var result = self
        if connected {
            if !parentGroupIDs.contains(parent) { result.parentGroupIDs.append(parent) }
        } else { result.parentGroupIDs.removeAll { $0 == parent } }
        return result
    }

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
        for id in leaderMemberIDs where parentID(of: id) == nil { if let root = members.first(where: { $0.id == id }) { visit(root, 0) } }
        for id in leaderMemberIDs where !visited.contains(id) { if let leader = members.first(where: { $0.id == id }) { visit(leader, 0) } }
        for member in members where !visited.contains(member.id) { visit(member, 0) }
        return result
    }

    public func parentCandidates(for memberID: UUID) -> [SessionGroupMember] {
        guard leaderMemberID != nil, members.contains(where: { $0.id == memberID }) else { return [] }
        var descendants = Set<UUID>([memberID]), queue = [memberID]
        while let next = queue.popLast() {
            for child in children(of: next) where descendants.insert(child.id).inserted { queue.append(child.id) }
        }
        return members.filter { !descendants.contains($0.id) && (!isLeader(memberID) || isLeader($0.id)) }
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

    public func settingParent(_ parentID: UUID?, for memberID: UUID) -> SessionGroup {
        guard let index = members.firstIndex(where: { $0.id == memberID }) else { return self }
        if let parentID {
            guard parentCandidates(for: memberID).contains(where: { $0.id == parentID }) else { return self }
        } else if !isLeader(memberID) { return self }
        var result = self
        result.members[index].assignedParentIDs = nil
        result.members[index].parentMemberID = !isLeader(memberID) && parentID == leaderMemberID ? nil : parentID
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
        for i in result.members.indices { result.members[i].assignedParentIDs?.removeAll { $0 == memberID } }
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
        let memberIDs = Set(members.map(\.id))
        guard !parentGroupIDs.contains(id), Set(parentGroupIDs).count == parentGroupIDs.count,
              members.allSatisfy({ member in
                  guard let parents = member.assignedParentIDs else { return true }
                  return !parents.contains(member.id) && Set(parents).count == parents.count && memberIDs.isSuperset(of: parents)
              }) else { throw AppError.message("중복되거나 존재하지 않는 그룹 관계입니다.") }
        try result.validateTree()
        return result
    }

    private func validateTree() throws {
        let invalid = AppError.message("그룹장과 상위 구성원 연결을 확인해주세요.")
        guard leaderMemberID != nil else {
            guard members.allSatisfy({ $0.parentMemberID == nil }) else { throw invalid }
            return
        }
        let byID = Dictionary(uniqueKeysWithValues: members.map { ($0.id, $0) })
        let leaders = Set(leaderMemberIDs)
        guard leaders.count == leaderMemberIDs.count, leaders.allSatisfy({ byID[$0] != nil }) else { throw invalid }
        var verified = Set<UUID>()
        for member in members {
            var path = Set<UUID>()
            var current = member
            while !verified.contains(current.id) {
                guard path.insert(current.id).inserted else { throw invalid }
                let isLeader = leaders.contains(current.id)
                guard let parent = current.parentMemberID ?? (isLeader ? nil : leaderMemberID) else { break }
                guard let next = byID[parent], !isLeader || leaders.contains(parent) else { throw invalid }
                current = next
            }
            verified.formUnion(path)
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
    var providerIdentityAmbiguous = false
    var codexIdentityFromMCP = false
    var inheritsClaudeConfigHome = false
    var claudePromptChannel: String?
    var claudeRegisteredStatus: String?
    var claudeRegisteredActivity: ClaudeSessionActivity?
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
    public var terminalPhase: SessionPhase? = nil
}

public enum SessionGroupMatching {
    package static func permitsIdentityRefresh(_ member: SessionGroupMember, candidate: SessionGroupLiveSession,
                                               conversation: UUID?, live: [SessionGroupLiveSession]) -> Bool {
        guard candidate.session.agent == member.agent, candidate.session.phase != .ended else { return false }
        if member.runtimeID == candidate.id, let savedTab = member.tabShell?.terminalSessionID,
           let currentTab = candidate.tabShell?.terminalSessionID, savedTab != currentTab { return false }
        let anchored = ownsTerminal(member, candidate)
        let previous = UUID(uuidString: member.conversationID)
        return !live.contains { other in
            guard other.id != candidate.id, other.session.phase != .ended else { return false }
            if other.id == member.runtimeID || member.tabShell?.identifies(other.tabShell) == true { return true }
            guard other.session.agent == member.agent,
                  other.providerHome == nil || candidate.providerHome == nil || other.providerHome == candidate.providerHome,
                  let observed = other.conversationID.flatMap(UUID.init(uuidString:)) else { return false }
            return observed == conversation || (!anchored && observed == previous)
        }
    }

    static func currentTerminal(_ member: SessionGroupMember, in live: [SessionGroupLiveSession]) -> SessionGroupLiveSession? {
        let matches = live.filter {
            $0.session.phase != .ended && ownsTerminal(member, $0) && $0.session.cwd == member.cwd &&
                (member.providerHome == nil || $0.providerHome == nil || member.providerHome == $0.providerHome)
        }
        return matches.count == 1 ? matches[0] : nil
    }

    static func followingTerminals(_ group: SessionGroup, live: [SessionGroupLiveSession], agents: Set<AgentKind>) -> SessionGroup {
        var result = group
        for (index, member) in group.members.enumerated() where agents.contains(member.agent) {
            guard let row = currentTerminal(member, in: live), let home = row.providerHome,
                  let conversation = row.conversationID.flatMap(UUID.init(uuidString:)),
                  permitsIdentityRefresh(member, candidate: row, conversation: conversation, live: live) else { continue }
            result.members[index].runtimeID = row.id
            result.members[index].conversationID = conversation.uuidString.lowercased()
            result.members[index].providerHome = home
            if row.tabShell != nil || member.runtimeID != row.id { result.members[index].tabShell = row.tabShell }
        }
        return (try? result.validated()) != nil ? result : group
    }

    public static func identityWarnings(_ group: SessionGroup, live: [SessionGroupLiveSession]) -> [UUID: String] {
        var warnings: [UUID: String] = [:]
        var named: [String: [UUID]] = [:]
        for member in group.members {
            let terminals = live.filter { $0.session.phase != .ended && ownsTerminal(member, $0) }
            if terminals.count > 1 { warnings[member.id] = "구성원에 해당하는 실행 중인 터미널이 여러 개입니다." }
            let endpoint = connection(member, in: live) ?? (terminals.count == 1 ? terminals.first : nil)
            if let endpoint, let name = endpoint.messagingName, !name.isEmpty {
                named[name, default: []].append(member.id)
            }
            if let endpoint, let saved = UUID(uuidString: member.conversationID),
               endpoint.conversationID.flatMap(UUID.init(uuidString:)) != nil,
               (endpoint.conversationID.flatMap(UUID.init(uuidString:)) != saved ||
                !permitsIdentityRefresh(member, candidate: endpoint, conversation: saved, live: live)) {
                warnings[member.id] = "저장된 대화 ID와 실행 중인 탭이 일치하지 않습니다."
            }
        }
        for ids in named.values where ids.count > 1 {
            for id in ids where warnings[id] == nil { warnings[id] = "같은 메시징 이름을 쓰는 구성원이 있습니다. 터미널과 대화 ID를 확인해주세요." }
        }
        return warnings
    }

    public static func ownsTerminal(_ member: SessionGroupMember, _ candidate: SessionGroupLiveSession) -> Bool {
        member.agent == candidate.session.agent && (member.runtimeID == candidate.id || member.tabShell?.identifies(candidate.tabShell) == true)
    }

    public static func restoringLeader(_ leaderID: UUID, from childID: UUID, in group: SessionGroup,
                                       target: SessionGroupLiveSession) throws -> SessionGroup {
        guard group.isLeader(leaderID), !group.isLeader(childID), group.parentID(of: childID) == leaderID,
              group.children(of: childID).isEmpty,
              let li = group.members.firstIndex(where: { $0.id == leaderID }),
              let ci = group.members.firstIndex(where: { $0.id == childID }),
              let id = target.conversationID.flatMap(UUID.init(uuidString:)),
              UUID(uuidString: group.members[ci].conversationID) == id,
              let home = target.providerHome,
              [group.members[li], group.members[ci]].allSatisfy({ $0.agent == target.session.agent &&
                  $0.cwd == target.session.cwd && ($0.providerHome == nil || $0.providerHome == home) })
        else { throw AppError.message("선택한 대화와 그룹장 또는 직속 구성원의 연결이 바뀌었습니다.") }
        var result = group
        result.members[li].runtimeID = target.id
        result.members[li].conversationID = id.uuidString.lowercased()
        result.members[li].tabShell = target.tabShell
        result.members[li].providerHome = home
        result.members[ci].runtimeID = nil
        result.members[ci].conversationID = ""
        result.members[ci].tabShell = nil
        return try result.validated()
    }

    public static func remainingLeaderCandidate(_ memberID: UUID, group: SessionGroup, groups: [SessionGroup],
                                                live: [SessionGroupLiveSession]) -> SessionGroupLiveSession? {
        guard group.isLeader(memberID), group.members.count > 1,
              let leader = group.members.first(where: { $0.id == memberID }),
              connection(leader, in: live) == nil,
              replacement(leader, in: live, selected: nil) == nil else { return nil }
        let peers = group.members.filter { $0.id != memberID }
        let connected = peers.compactMap { peer -> String? in
            guard let id = UUID(uuidString: peer.conversationID), let row = match(peer, in: live),
                  row.conversationID.flatMap(UUID.init(uuidString:)) == id else { return nil }
            return row.id
        }
        let occupied = Set(connected)
        guard occupied.count == peers.count else { return nil }
        let home = leader.providerHome ?? (leader.agent == .claude ? TerminalProfileGroup.normalizedHome(nil, agent: "claude") : nil)
        let otherMembers = groups.filter { $0.id != group.id }.flatMap(\.members)
        let possible = live.filter { row in
            guard !occupied.contains(row.id), row.session.phase != .ended, row.session.agent == leader.agent,
                  row.session.cwd == leader.cwd, row.providerHome == nil || row.providerHome == home else { return false }
            let id = row.conversationID.flatMap(UUID.init(uuidString:))
            return !otherMembers.contains { other in
                other.runtimeID == row.id || other.tabShell?.identifies(row.tabShell) == true ||
                    (id != nil && other.agent == row.session.agent && UUID(uuidString: other.conversationID) == id &&
                        (other.providerHome == nil || other.providerHome == row.providerHome))
            }
        }
        guard possible.count == 1, let candidate = possible.first, candidate.conversationID.flatMap(UUID.init(uuidString:)) != nil,
              !(leader.tabShell?.terminalSessionID.flatMap { saved in candidate.tabShell?.terminalSessionID.map { $0 != saved } } ?? false),
              permitsIdentityRefresh(leader, candidate: candidate, conversation: candidate.conversationID.flatMap(UUID.init(uuidString:)), live: live),
              replacement(leader, in: live, selected: candidate.id)?.id == candidate.id else { return nil }
        return candidate
    }

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
        groups.map { saved in
            let group = followingTerminals(saved, live: live, agents: [.claude, .agy])
            var updated = group
            for (index, member) in group.members.enumerated() where member.agent == .claude || member.agent == .agy {
                if let resumed = match(member, in: live), resumed.id != member.runtimeID,
                   permitsIdentityRefresh(member, candidate: resumed, conversation: UUID(uuidString: member.conversationID), live: live),
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
                      permitsIdentityRefresh(member, candidate: endpoint, conversation: fresh, live: live),
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
        if let tab = currentTerminal(member, in: live) { return tab }
        let candidates = live.filter {
            $0.id == member.runtimeID && $0.session.agent == member.agent &&
            $0.session.phase != .ended && $0.session.cwd == member.cwd &&
            (member.providerHome == nil || $0.providerHome == nil || member.providerHome == $0.providerHome)
        }
        if candidates.count == 1 { return candidates[0] }
        guard candidates.isEmpty else { return nil }
        return match(member, in: live)
    }

    package static func policySession(_ member: SessionGroupMember, in live: [SessionGroupLiveSession]) -> SessionGroupLiveSession? {
        if let match = match(member, in: live) { return match.providerIdentityAmbiguous ? nil : match }
        guard let saved = UUID(uuidString: member.conversationID), let tab = member.tabShell,
              let row = currentTerminal(member, in: live), row.id == member.runtimeID,
              tab.identifies(row.tabShell), !row.providerIdentityAmbiguous, row.conversationID == nil,
              member.providerHome == nil || member.providerHome == row.providerHome,
              permitsIdentityRefresh(member, candidate: row, conversation: saved, live: live) else { return nil }
        let otherEvidence = [row.session.codexApprovalBinding?.threadID, row.session.providerID].compactMap { $0 }
        return otherEvidence.allSatisfy { UUID(uuidString: $0) == saved } ? row : nil
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
        guard matches.count == 1, let candidate = matches.first,
              permitsIdentityRefresh(member, candidate: candidate, conversation: UUID(uuidString: member.conversationID), live: live) else { return nil }
        return candidate
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
        let ids = Set(groups.map(\.id))
        guard groups.count <= 200, ids.count == groups.count, groups.allSatisfy({ ids.isSuperset(of: $0.parentGroupIDs) }) else {
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
        let ids = Set(values.map(\.id))
        guard values.count <= 200, ids.count == values.count, values.allSatisfy({ ids.isSuperset(of: $0.parentGroupIDs) }) else {
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
