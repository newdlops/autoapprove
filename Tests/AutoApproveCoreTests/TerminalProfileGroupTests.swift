import Foundation
import AutoApproveCore

extension ApprovalTests {
    func testTerminalProfileGroupsSavePortableHierarchyAndSelection() throws {
        let home="/fixture/home",cwd="/fixture/project"
        var leader=SessionGroupMember(agent:.codex,title:"Leader",cwd:cwd,conversationID:UUID().uuidString.lowercased(),providerHome:home)
        var worker=SessionGroupMember(agent:.codex,title:"Worker",cwd:cwd,conversationID:UUID().uuidString.lowercased(),providerHome:home)
        var child=SessionGroupMember(agent:.claude,title:"Claude",cwd:cwd,conversationID:UUID().uuidString.lowercased(),providerHome:"/fixture/claude")
        leader.runtimeID="old-leader";worker.runtimeID="old-worker";child.runtimeID="old-claude";child.parentMemberID=worker.id
        let group=SessionGroup(name:"Saved group",members:[leader,worker,child],leaderMemberID:leader.id).addingLeader(worker.id).settingParent(leader.id, for: worker.id)
        let entries=[leader,worker].map {TerminalProfileEntry(title:$0.title,agent:$0.agent.rawValue,cwd:$0.cwd,conversationID:$0.conversationID,providerHome:$0.providerHome)}
        let candidates=zip([leader,worker],entries).map {TerminalProfileCandidate(id:$0.0.runtimeID!,entry:$0.1)}
        let groups=TerminalProfileGroup.capture([group],candidates:candidates)
        let profile=TerminalSessionProfile(name:"Groups",entries:entries,groups:groups)
        let decoded=try TerminalProfileStore.decode(TerminalProfileStore.encode(profile))
        try expectEqual(decoded.schema,4);try expectEqual(decoded.groups,groups)
        try expectEqual(decoded.groups?.first?.group.leaderMemberIDs,[leader.id, worker.id])
        try expectEqual(decoded.groups?.first?.group.members.last?.parentMemberID,worker.id)
        try expect(decoded.groups!.allSatisfy {$0.group.members.allSatisfy {$0.runtimeID==nil}})
        var selected=entries[1];selected.conversationID=""
        let subset=TerminalProfileGroup.selecting(groups,entries:[selected])
        let one=try TerminalSessionProfile(name:"One",entries:[selected],groups:subset).validated()
        try expectEqual(one.groups?.first?.links.map(\.entryID),[selected.id])
        try expectEqual(one.groups?.first?.group.members.first(where:{$0.id==worker.id})?.conversationID,"")
        var replacement = leader
        replacement.id = UUID()
        let current = SessionGroup(id: group.id, name: group.name, members: [replacement], leaderMemberID: replacement.id)
        let resolved = try TerminalProfileGroupRestore.resolveMemberIDs(groups, in: [current])
        try expectEqual(resolved[0].group.leaderMemberID, replacement.id)
        try expectEqual(resolved[0].group.parentID(of: worker.id), replacement.id)
        let restored = try TerminalProfileGroupRestore.merge(resolved, into: [current], restored: [entries[1].id])
        try expectEqual(restored[0].parentID(of: worker.id), replacement.id)
        try expect(restored[0].canDirect(replacement.id, worker: worker.id))
        try expect(resolved[0].links.contains { $0.memberID == replacement.id })
        try expectFalse(resolved[0].group.members.contains { $0.id == leader.id })
        try expectEqual(try TerminalProfileGroupRestore.resolveMemberIDs(resolved, in: [current]), resolved)
        let conversation = UUID().uuidString.lowercased()
        let importedLeader = SessionGroupMember(agent: .claude, title: "Claude", cwd: cwd, conversationID: conversation)
        let importedGroup = SessionGroup(name: "Imported", members: [importedLeader], leaderMemberID: importedLeader.id)
        let importedEntry = UUID()
        let imported = TerminalProfileGroup(group: importedGroup, links: [.init(entryID: importedEntry, memberID: importedLeader.id)])
        let loaded = try TerminalProfileGroupRestore.merge([imported], into: [], restored: [importedEntry])
        let runtime = AgentSession(id: "new-process", agent: .claude, pid: 123, started: "new", tty: "/dev/ttys999", cwd: cwd, terminal: .terminal)
        let live = SessionGroupLiveSession(session: runtime, conversationID: conversation, providerHome: NSHomeDirectory() + "/.claude")
        try expectEqual(SessionGroupMatching.match(loaded[0].members[0], in: [live])?.id, runtime.id)
        var invalid=profile;invalid.groups![0].links[0].entryID=UUID()
        try expectThrows(invalid.validated())
        invalid=profile;invalid.groups![0].group.members[0].runtimeID="stale-pid"
        try expectThrows(invalid.validated())
        var legacy=profile;legacy.schema=2;legacy.groups=nil
        try expectEqual(try TerminalProfileStore.decode(TerminalProfileStore.encode(legacy)).groups,nil)
        let unrelated=SessionGroup(name:"Other",members:[])
        try expectEqual(try TerminalProfileGroupRestore.merge(groups,into:[unrelated],restored:[]),[unrelated])
        let merged=try TerminalProfileGroupRestore.merge(groups,into:[unrelated],restored:[entries[1].id])
        try expectEqual(merged.first,unrelated);try expectEqual(merged.last,groups[0].group)
        try expectEqual(try TerminalProfileGroupRestore.merge(groups,into:merged,restored:[entries[1].id]),merged)
    }

    @MainActor func testTerminalProfileGroupsReconnectReceiptsWithoutClaimingConversation() async throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("profile-groups-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:directory)}
        let home="/fixture/home",cwd="/fixture/project",id=UUID().uuidString.lowercased()
        let record=ProcessDiscovery.parse("100751 1 ttys751 100751 100751 Wed Oct 28 12:00:00 2026 /fixture/codex")[0]
        let session=AgentSession(id:record.key,agent:.codex,pid:record.pid,started:record.started,tty:"/dev/"+record.tty,cwd:cwd,terminal:.terminal)
        let engine=try ApprovalEngine(paths:AppPaths(directory:directory),processReader:{[record]},codexGroupReader:{_ in nil},codexGroupEnvironment:{_ in ["CODEX_HOME":home]})
        defer {engine.stop()}
        let entry=TerminalProfileEntry(title:"Restored",agent:"codex",cwd:cwd,conversationID:id,providerHome:home)
        var member=SessionGroupMember(agent:.codex,title:"Worker",cwd:cwd,conversationID:id,providerHome:home);member.runtimeID="old-runtime"
        let leader=SessionGroupMember(agent:.codex,title:"Offline leader",cwd:cwd,conversationID:UUID().uuidString.lowercased(),providerHome:home)
        let group=SessionGroup(name:"Saved group",members:[leader,member],leaderMemberID:leader.id)
        let previous=[TerminalProfileCandidate(id:"old-runtime",entry:entry)]
        let snapshots=TerminalProfileGroup.capture([group],candidates:previous)
        let profile=TerminalSessionProfile(name:"Restore",entries:[entry],groups:snapshots)
        // The command receipt can arrive before process discovery. Retain it until discovery catches up.
        try await engine.restoreTerminalProfileGroups(profile,results:[.init(id:entry.id,phase:.opened,detail:"sent",tty:session.tty)],previous:previous)
        engine.updateDiscovery([session],records:[record])
        let live=try await engine.sessionGroupSessions()
        let restored=try SessionGroupStore(directory:directory).load()[0]
        try expectEqual(restored.members[1].runtimeID,record.key)
        try expectEqual(restored.leaderMemberID,leader.id)
        try expectEqual(SessionGroupMatching.connection(restored.members[1],in:live)?.id,record.key)
        try expectNil(SessionGroupMatching.match(restored.members[1],in:live))
        try expectEqual(SessionGroupBadge.badges(groups:[restored],live:live)[record.key]?.parentMemberID,leader.id)
        // Legacy profiles reconnect exact saved identities as well, without changing group metadata.
        try SessionGroupStore(directory:directory).save([group])
        var legacy=profile;legacy.schema=2;legacy.groups=nil
        try await engine.restoreTerminalProfileGroups(legacy,results:[.init(id:entry.id,phase:.opened,detail:"sent",tty:session.tty)],previous:previous)
        try expectEqual(try SessionGroupStore(directory:directory).load()[0].members[1].runtimeID,record.key)
        // A failed launch has no authority to reconnect an old or unrelated process.
        try SessionGroupStore(directory:directory).save([group])
        try await engine.restoreTerminalProfileGroups(legacy,results:[.init(id:entry.id,phase:.failed,detail:"failed",tty:session.tty)],previous:previous)
        try expectEqual(try SessionGroupStore(directory:directory).load(),[group])
    }
}
