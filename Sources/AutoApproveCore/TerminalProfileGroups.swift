import Foundation

/// Portable group definitions link to profile entries, never saved PIDs or TTYs.
public struct TerminalProfileGroup: Codable, Equatable, Sendable {
    public struct Link: Codable, Equatable, Sendable {
        public var entryID:UUID
        public var memberID:UUID
        public init(entryID:UUID,memberID:UUID) {self.entryID=entryID;self.memberID=memberID}
    }
    public var group:SessionGroup
    public var links:[Link]
    public init(group:SessionGroup,links:[Link]) {self.group=group;self.links=links}

    static func sameConversation(_ member:SessionGroupMember,_ entry:TerminalProfileEntry) -> Bool {
        guard let id=UUID(uuidString:member.conversationID),let other=UUID(uuidString:entry.conversationID) else{return false}
        return member.agent.rawValue==entry.agent && member.cwd==entry.cwd && id==other &&
            normalizedHome(member.providerHome,agent:entry.agent)==normalizedHome(entry.providerHome,agent:entry.agent)
    }
    static func normalizedHome(_ home:String?,agent:String) -> String {
        URL(fileURLWithPath:home ?? (agent=="agy" ? AgyHookInstaller.file.deletingLastPathComponent().path : NSHomeDirectory()+"/."+agent)).standardizedFileURL.resolvingSymlinksInPath().path
    }
    public func validated(entries:[TerminalProfileEntry]) throws -> Self {
        var copy=self;copy.group=try group.validated()
        guard !links.isEmpty,links.count<=128,Set(links.map(\.entryID)).count==links.count,
              Set(links.map(\.memberID)).count==links.count,group.members.allSatisfy({$0.runtimeID==nil && $0.tabShell==nil}) else {
            throw AppError.message("프로필의 그룹 구성원 연결을 확인해주세요.")
        }
        for link in links {
            guard let entry=entries.first(where:{$0.id==link.entryID}),
                  let member=copy.group.members.first(where:{$0.id==link.memberID}),
                  member.agent.rawValue==entry.agent,member.cwd==entry.cwd,
                  member.conversationID==entry.conversationID,
                  Self.normalizedHome(member.providerHome,agent:entry.agent)==Self.normalizedHome(entry.providerHome,agent:entry.agent) else {
                throw AppError.message("프로필의 세션과 그룹 구성원 정보가 다릅니다.")
            }
        }
        return copy
    }
    public static func capture(_ groups:[SessionGroup],candidates:[TerminalProfileCandidate]) -> [Self] {
        groups.compactMap { original in
            var group=original,links:[Link]=[]
            for index in group.members.indices {
                let member=group.members[index]
                let terminal=candidates.filter {
                    $0.id==member.runtimeID && $0.entry.agent==member.agent.rawValue && $0.entry.cwd==member.cwd &&
                    (member.providerHome==nil || normalizedHome($0.entry.providerHome,agent:$0.entry.agent)==normalizedHome(member.providerHome,agent:$0.entry.agent))
                }
                let matches=terminal.isEmpty ? candidates.filter {sameConversation(member,$0.entry)} : terminal
                if matches.count==1,let entry=matches.first?.entry {
                    group.members[index].conversationID=entry.conversationID
                    group.members[index].providerHome=entry.providerHome
                    links.append(.init(entryID:entry.id,memberID:member.id))
                }
                group.members[index].runtimeID=nil;group.members[index].tabShell=nil
            }
            return links.isEmpty ? nil:Self(group:group,links:links)
        }
    }
    /// An editor can omit entries, select a conversation, or explicitly start a new CLI.
    public static func selecting(_ groups:[Self],entries:[TerminalProfileEntry]) -> [Self] {
        groups.compactMap { original in
            var value=original
            value.links=original.links.filter {link in entries.contains {$0.id==link.entryID}}
            guard !value.links.isEmpty else{return nil}
            for link in value.links {
                guard let entry=entries.first(where:{$0.id==link.entryID}),let index=value.group.members.firstIndex(where:{$0.id==link.memberID}) else{continue}
                guard let agent=AgentKind(rawValue:entry.agent) else {continue}
                value.group.members[index].agent=agent
                value.group.members[index].cwd=entry.cwd
                value.group.members[index].conversationID=entry.conversationID
                value.group.members[index].providerHome=entry.providerHome
                value.group.members[index].runtimeID=nil;value.group.members[index].tabShell=nil
            }
            return value
        }
    }
}

/// A newly opened tab is sufficient for displaying group membership, not for
/// addressing a conversation. Messaging still requires SessionGroupMatching.match.
struct TerminalProfileGroupAttachment {
    var groupID:UUID
    var memberID:UUID
    var entry:TerminalProfileEntry
    var tty:String
    var excludedRuntimes:Set<String>
    var expires:Date
    func match(_ live:[SessionGroupLiveSession]) -> SessionGroupLiveSession? {
        let matches=live.filter {
            $0.session.phase != .ended && !excludedRuntimes.contains($0.id) &&
            $0.session.tty==tty && $0.session.cwd==entry.cwd && $0.session.agent.rawValue==entry.agent &&
            $0.session.terminal == (entry.host == .terminal ? .terminal:.iterm) &&
            ($0.providerHome==nil || TerminalProfileGroup.normalizedHome($0.providerHome,agent:entry.agent)==TerminalProfileGroup.normalizedHome(entry.providerHome,agent:entry.agent)) &&
            ($0.conversationID==nil || !entry.resumesConversation || $0.conversationID.flatMap(UUID.init(uuidString:))==UUID(uuidString:entry.conversationID))
        }
        return matches.count==1 ? matches[0]:nil
    }
}

public enum TerminalProfileGroupRestore {
    package static func resolveMemberIDs(_ snapshots: [TerminalProfileGroup], in groups: [SessionGroup]) throws -> [TerminalProfileGroup] {
        try snapshots.map { snapshot in
            guard let current = groups.first(where: { $0.id == snapshot.group.id }) else { return snapshot }
            var ids: [UUID: UUID] = [:]
            let original = snapshot.group
            for saved in original.members where !current.members.contains(where: { $0.id == saved.id }) {
                guard let conversation = UUID(uuidString: saved.conversationID) else { continue }
                let matches = current.members.filter {
                    $0.agent == saved.agent && UUID(uuidString: $0.conversationID) == conversation &&
                        TerminalProfileGroup.normalizedHome($0.providerHome, agent: saved.agent.rawValue) ==
                        TerminalProfileGroup.normalizedHome(saved.providerHome, agent: saved.agent.rawValue)
                }
                guard matches.count <= 1 else { throw AppError.message("같은 대화에 여러 그룹 구성원이 연결되어 있습니다.") }
                if let match = matches.first { ids[saved.id] = match.id }
            }
            guard !ids.isEmpty else { return snapshot }
            let members = original.members.map { saved in
                var member = saved
                member.id = ids[saved.id] ?? saved.id
                member.parentMemberID = saved.parentMemberID.map { ids[$0] ?? $0 }
                return member
            }
            guard Set(members.map(\.id)).count == members.count else { throw AppError.message("프로필의 여러 구성원이 같은 대화에 연결됩니다.") }
            var group = SessionGroup(id: original.id, name: original.name, members: members)
            for leader in original.leaderMemberIDs { group = group.addingLeader(ids[leader] ?? leader) }
            group.members = members
            return TerminalProfileGroup(group: try group.validated(), links: snapshot.links.map {
                .init(entryID: $0.entryID, memberID: ids[$0.memberID] ?? $0.memberID)
            })
        }
    }

    public static func merge(_ snapshots:[TerminalProfileGroup],into current:[SessionGroup],restored:Set<UUID>) throws -> [SessionGroup] {
        var result=current
        for snapshot in snapshots where snapshot.links.contains(where:{restored.contains($0.entryID)}) {
            guard let gi=result.firstIndex(where:{$0.id==snapshot.group.id}) else {
                var group = snapshot.group
                let linked = Set(snapshot.links.filter { restored.contains($0.entryID) }.map(\.memberID))
                for i in group.members.indices where linked.contains(group.members[i].id) && group.members[i].providerHome == nil {
                    group.members[i].providerHome = TerminalProfileGroup.normalizedHome(nil, agent: group.members[i].agent.rawValue)
                }
                result.append(group)
                continue
            }
            let existingMemberIDs = Set(result[gi].members.map(\.id))
            for saved in snapshot.group.members where !result[gi].members.contains(where:{$0.id==saved.id}) {
                guard !result[gi].members.contains(where:{$0.agent==saved.agent && !$0.conversationID.isEmpty && $0.conversationID==saved.conversationID && $0.providerHome==saved.providerHome}) else{continue}
                var member=saved
                if result[gi].leaderMemberID==nil || !result[gi].members.contains(where:{$0.id==member.parentMemberID}) {member.parentMemberID=nil}
                result[gi].members.append(member)
            }
            let hadLeader = result[gi].leaderMemberID != nil
            for leader in snapshot.group.leaderMemberIDs where !hadLeader || !existingMemberIDs.contains(leader) {
                result[gi] = result[gi].addingLeader(leader)
            }
            if result[gi].leaderMemberID != nil {
                for saved in snapshot.group.members where !hadLeader || !existingMemberIDs.contains(saved.id) {
                    guard let index=result[gi].members.firstIndex(where:{$0.id==saved.id}) else{continue}
                    if let parent = saved.parentMemberID, !result[gi].members.contains(where: { $0.id == parent }) { continue }
                    result[gi].members[index].parentMemberID=saved.parentMemberID
                }
            }
            for link in snapshot.links where restored.contains(link.entryID) {
                guard let saved=snapshot.group.members.first(where:{$0.id==link.memberID}),
                      let index=result[gi].members.firstIndex(where:{$0.id==link.memberID}) else{continue}
                var member=result[gi].members[index]
                if member.agent != saved.agent || member.cwd != saved.cwd || member.conversationID != saved.conversationID || TerminalProfileGroup.normalizedHome(member.providerHome,agent:member.agent.rawValue) != TerminalProfileGroup.normalizedHome(saved.providerHome,agent:saved.agent.rawValue) {member.runtimeID=nil;member.tabShell=nil}
                member.agent=saved.agent;member.cwd=saved.cwd;member.conversationID=saved.conversationID;member.providerHome=saved.providerHome ?? TerminalProfileGroup.normalizedHome(nil,agent:saved.agent.rawValue)
                result[gi].members[index]=member
            }
        }
        return try result.map {try $0.validated()}
    }
}
