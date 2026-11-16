#if DEBUG
import Foundation
@testable import AutoApproveCore

@MainActor private final class CohortRestartProbe {
    var alive=Set<UUID>()
    var restored:[UUID:String]=[:]
    var restarted=false,transferred=false,lostLaunch=false
    var restarts=0,transfers=0,launches=0,groupRestores=0
}

extension ApprovalTests {
    func testCohortProcessFencePreservesAncestryAcrossParentExitAndPIDReuse()throws {
        let records=ProcessDiscovery.parse("""
        50101 1 ttys991 50101 50101 Mon Nov 2 10:00:00 2026 /owned/codex
        50102 50101 ttys991 50101 50101 Mon Nov 2 10:00:01 2026 /owned/codex-code-mode-host
        50103 50102 ?? 50103 0 Mon Nov 2 10:00:02 2026 /usr/bin/sleep
        50104 1 ttys991 50104 50104 Mon Nov 2 10:00:03 2026 /unrelated/python
        50105 1 ttys992 50105 50105 Mon Nov 2 10:00:04 2026 /owned/codex
        50106 50105 ttys992 50105 50105 Mon Nov 2 10:00:05 2026 /unrelated/worker
        """)
        let captured=try CodexCohortProcessFence.capture(rootID:records[0].key,records:records)
        try expectEqual(Set(captured.map(\.pid)),Set<Int32>([50101,50102,50103]))
        let cold=try JSONDecoder().decode([ProcessRecord].self,from:JSONEncoder().encode(captured))
        var orphan=records.filter{$0.pid != 50101}
        for index in orphan.indices {
            if orphan[index].pid==50102 {orphan[index].parent=1}
            if orphan[index].pid==50103 {orphan[index].parent=1;orphan[index].started="Mon Nov 2 11:00:02 2026"}
        }
        orphan += ProcessDiscovery.parse("50107 50102 ttys992 50107 0 Mon Nov 2 10:00:06 2026 /owned/helper")
        let refreshed=try CodexCohortProcessFence.capture(rootID:records[0].key,records:orphan,previous:cold)
        try expectEqual(Set(CodexCohortProcessFence.live(refreshed,records:orphan).map(\.pid)),Set<Int32>([50102,50107]),"A reparented owned helper stays tracked; reused PID and unrelated shared TTY do not")
        try expectEqual(Set(CodexCohortProcessFence.live(cold,records:orphan).map(\.pid)),Set<Int32>([50102]))
        try expectThrows(CodexCohortProcessFence.capture(rootID:records[0].key,records:records,previous:[records[1],records[1]]))
    }
    func testCohortRestartMovesOnlySelectedHomeAndPreservesGroupRoles() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("aa-cohort-plan-"+UUID().uuidString)
        let source=root.appendingPathComponent("source"),destination=root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at:source,withIntermediateDirectories:true)
        try FileManager.default.createDirectory(at:destination,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:root)}
        let records=ProcessDiscovery.parse("5001 1 ttys991 5001 5001 Mon Nov 2 10:00:00 2026 /owned/codex\n5002 1 ttys992 5002 5002 Mon Nov 2 10:00:00 2026 /owned/codex")
        let entries=(0..<2).map{TerminalProfileEntry(title:"Terminal \($0)",agent:"codex",cwd:root.path,conversationID:UUID().uuidString.lowercased(),providerHome:source.path)}
        let candidates=records.enumerated().map{TerminalProfileCandidate(id:$0.element.key,entry:entries[$0.offset],tty:"/dev/"+$0.element.tty)}
        let leader=SessionGroupMember(agent:.codex,title:"Leader",cwd:root.path,conversationID:entries[0].conversationID,providerHome:source.path)
        var worker=SessionGroupMember(agent:.codex,title:"Worker",cwd:root.path,conversationID:entries[1].conversationID,providerHome:source.path)
        worker.parentMemberID=leader.id
        let group=SessionGroup(name:"Preserved group",members:[leader,worker],leaderMemberID:leader.id)
        let plan=try CodexCohortRestartPlan.capture(sourceHome:source.path,destinationHome:destination.path,candidates:candidates,records:records,movingSessionIDs:[records[0].key],groups:[group])
        // Read a cold serialized copy: restoration cannot rely on live pointers.
        let cold=try JSONDecoder().decode(CodexCohortRestartPlan.self,from:JSONEncoder().encode(plan))
        try expectEqual(cold,plan)
        try expectEqual(cold.members.count,2)
        try expectEqual(cold.restored.entries[0].providerHome,try CodexAccountTransitionTarget.canonicalHome(destination.path))
        try expectEqual(cold.restored.entries[1].providerHome,source.path)
        try expectEqual(cold.original.entries,entries)
        try expectEqual(cold.restored.entries.map(\.conversationID),entries.map(\.conversationID))
        let restored=try cold.restored.groups![0].validated(entries:cold.restored.entries)
        try expectEqual(restored.group.id,group.id)
        try expectEqual(restored.group.leaderMemberID,leader.id)
        try expectEqual(restored.group.members[1].parentMemberID,leader.id)
        try expectEqual(restored.group.members[0].providerHome,cold.destinationHome)
        try expectEqual(restored.group.members[1].providerHome,source.path)
        var missing=candidates;missing[1].entry.conversationID=""
        try expectThrows(CodexCohortRestartPlan.capture(sourceHome:source.path,destinationHome:destination.path,candidates:missing,records:records,movingSessionIDs:[records[0].key],groups:[group]))
        try expectThrows(CodexCohortRestartPlan.capture(sourceHome:source.path,destinationHome:destination.path,candidates:candidates,records:[records[0]],movingSessionIDs:[records[0].key],groups:[group]))
        let probe=CohortRestartProbe();probe.alive=Set(entries.map(\.id))
        let database=root.appendingPathComponent("restart.sqlite").path
        let driver=CodexCohortRestart(store:try AuditStore(path:database))
        _=try driver.prepare(plan)
        try expectThrows(driver.prepare(plan))
        let services=CodexCohortRestartServices(validate:{},originalAlive:{probe.alive.contains($0.entryID)},stop:{probe.alive.remove($0.entryID)},
            serverRestarted:{probe.restarted},restartServer:{
                try expect(probe.alive.isEmpty,"Every affected original must exit before server restart")
                probe.restarts+=1;probe.restarted=true
            },transferComplete:{probe.transferred},advanceTransfer:{
                try expect(probe.restarted);probe.transfers+=1;probe.transferred=true
            },observeRestored:{entry,_ in probe.restored[entry.id]},restore:{entry,_ in
                try expect(probe.transferred)
                probe.launches+=1;probe.restored[entry.id]="/dev/ttys\(970+probe.launches)"
                if !probe.lostLaunch {probe.lostLaunch=true;throw AppError.message("Controller lost launch result")}
            },restoreGroups:{profile,ttys in
                try expectEqual(profile,plan.restored);try expectEqual(ttys.count,2);probe.groupRestores+=1
            })
        var lost=false
        do {_=try await driver.advance(plan.id,services:services)}catch{lost=true}
        try expect(lost)
        try expectEqual(try driver.state(plan.id)?.phase,.restoring)
        // Recreate the coordinator and database connection. The external world
        // reports that the launch happened despite the missing controller reply.
        let recreated=CodexCohortRestart(store:try AuditStore(path:database))
        let finished=try await recreated.advance(plan.id,services:services)
        try expectEqual(finished.phase,.completed)
        try expectEqual(probe.restarts,1);try expectEqual(probe.transfers,1)
        try expectEqual(probe.launches,2,"One launch per terminal across controller recreation")
        try expectEqual(probe.groupRestores,1)
        _=try await recreated.advance(plan.id,services:services)
        try expectEqual(probe.launches,2);try expectEqual(probe.groupRestores,1)
        try expectEqual(try recreated.active().count,0)
    }
}
#endif
