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
        URL(fileURLWithPath:home ?? NSHomeDirectory()+"/."+agent).standardizedFileURL.resolvingSymlinksInPath().path
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
                let matches=candidates.filter {
                    ($0.id==member.runtimeID && $0.entry.agent==member.agent.rawValue && $0.entry.cwd==member.cwd &&
                     normalizedHome($0.entry.providerHome,agent:$0.entry.agent)==normalizedHome(member.providerHome,agent:$0.entry.agent)) || sameConversation(member,$0.entry)
                }
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
                value.group.members[index].agent=entry.agent=="codex" ? .codex:.claude
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
    /// Preserve unrelated groups and later edits to an existing group's structure.
    public static func merge(_ snapshots:[TerminalProfileGroup],into current:[SessionGroup],restored:Set<UUID>) throws -> [SessionGroup] {
        var result=current
        for snapshot in snapshots where snapshot.links.contains(where:{restored.contains($0.entryID)}) {
            guard let gi=result.firstIndex(where:{$0.id==snapshot.group.id}) else {
                result.append(snapshot.group);continue
            }
            let existingMemberIDs = Set(result[gi].members.map(\.id))
            for saved in snapshot.group.members where !result[gi].members.contains(where:{$0.id==saved.id}) {
                // A separately edited group can already contain this conversation under another member ID.
                guard !result[gi].members.contains(where:{$0.agent==saved.agent && !$0.conversationID.isEmpty && $0.conversationID==saved.conversationID && $0.providerHome==saved.providerHome}) else{continue}
                var member=saved
                if result[gi].leaderMemberID==nil || !result[gi].members.contains(where:{$0.id==member.parentMemberID}) {member.parentMemberID=nil}
                result[gi].members.append(member)
            }
            let hadLeader = result[gi].leaderMemberID != nil
            for leader in snapshot.group.leaderMemberIDs where !hadLeader || !existingMemberIDs.contains(leader) {
                result[gi] = result[gi].addingLeader(leader)
            }
            if !hadLeader, result[gi].leaderMemberID != nil {
                for saved in snapshot.group.members {
                    guard let index=result[gi].members.firstIndex(where:{$0.id==saved.id}) else{continue}
                    result[gi].members[index].parentMemberID=saved.parentMemberID
                }
            }
            for link in snapshot.links where restored.contains(link.entryID) {
                guard let saved=snapshot.group.members.first(where:{$0.id==link.memberID}),
                      let index=result[gi].members.firstIndex(where:{$0.id==link.memberID}) else{continue}
                var member=result[gi].members[index]
                if member.agent != saved.agent || member.cwd != saved.cwd || member.conversationID != saved.conversationID || member.providerHome != saved.providerHome {member.runtimeID=nil;member.tabShell=nil}
                member.agent=saved.agent;member.cwd=saved.cwd;member.conversationID=saved.conversationID;member.providerHome=saved.providerHome
                result[gi].members[index]=member
            }
        }
        return try result.map {try $0.validated()}
    }
}
