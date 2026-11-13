import Foundation
import Darwin

/// A saved collaboration group identifies conversations, not processes or projects.
public struct SessionGroupMember: Codable, Equatable, Identifiable {
    public var id: UUID
    public var agent: AgentKind
    public var title: String
    public var cwd: String
    public var conversationID: String
    public var providerHome: String?
    /// A live process identity helps present an unresolved member, never a replacement for a conversation ID.
    public var runtimeID: String? = nil

    public init(id: UUID = UUID(), agent: AgentKind, title: String, cwd: String,
                conversationID: String, providerHome: String? = nil) {
        self.id = id; self.agent = agent; self.title = title; self.cwd = cwd
        self.conversationID = conversationID; self.providerHome = providerHome
    }
}

public struct SessionGroup: Codable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var members: [SessionGroupMember]

    public init(id: UUID = UUID(), name: String, members: [SessionGroupMember] = []) {
        self.id = id; self.name = name; self.members = members
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
        return result
    }
}

/// Current observation, kept separate from the persisted group entry.
public struct SessionGroupLiveSession: Identifiable, Equatable {
    public var session: AgentSession
    public var conversationID: String?
    public var providerHome: String?
    public var messagingName: String?
    public var id: String { session.id }
    public init(session: AgentSession, conversationID: String?, providerHome: String?, messagingName: String? = nil) {
        self.session = session; self.conversationID = conversationID; self.providerHome = providerHome; self.messagingName = messagingName
    }
    public var member: SessionGroupMember {
        let title = String(session.displayedTerminalTitle.components(separatedBy: .newlines).joined(separator: " ")
            .unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(String.init).joined().prefix(256))
        var value = SessionGroupMember(agent: session.agent, title: title,
            cwd: session.cwd, conversationID: conversationID ?? "", providerHome: providerHome)
        value.runtimeID = session.id
        return value
    }
}

public enum SessionGroupMatching {
    /// A conversation can be attached only when one exact live observation matches.
    public static func match(_ member: SessionGroupMember, in live: [SessionGroupLiveSession]) -> SessionGroupLiveSession? {
        let matches = live.filter { observation in
            guard observation.session.agent == member.agent, observation.session.phase != .ended else { return false }
            if member.conversationID.isEmpty {
                return member.runtimeID == observation.id && member.cwd == observation.session.cwd
            }
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
