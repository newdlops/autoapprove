import Foundation
import AutoApproveCore

@main struct AccountContinuationCheck {
    @MainActor static func main() async throws {
        let args=CommandLine.arguments
        var target=CodexAccountTransitionTarget(home:args[1],executable:args[2])
        let scenario=args.count>3 ? args[3]:"normal"
        let official=["official","official-switch"].contains(scenario),review=["blocked","lost-ack"].contains(scenario)
        if official {
            guard target.home.hasPrefix("/private/tmp/aa-account-real-cli-"),args.count==7 else {throw AppError.message("Three owned temporary TUIs required")}
            let pids=Set(args.dropFirst(4).compactMap(Int32.init))
            guard pids.count==3 else {throw AppError.message("Owned original process identities missing")}
            let records=try ProcessDiscovery.read().filter{pids.contains($0.pid)}
            let discovered=try await CodexAccountTransitionTarget.discover(records)
            let canonical=try CodexAccountTransitionTarget.canonicalHome(target.home)
            guard discovered.count==1,discovered[0].home==canonical,discovered[0].witnesses.count==3 else {throw AppError.message("Owned common server missing: processes \(records.count), targets \(discovered.count), witnesses \(discovered.map{$0.witnesses.count}), canonicalHome \(discovered.first?.home==canonical), fixtureHomes \(discovered.map{$0.home.hasPrefix("/private/tmp/aa-account-real-cli-") ? $0.home:"outside-owned-fixture"})")}
            target=discovered[0]
        }
        var services=CodexAccountTransitionServices.live
        let liveRestart=services.restart
        let liveResume=services.resume
        var continuationCalls:[String:Int]=[:]
        if let liveResume {
            services.resume={target,expected,original,receipt in
                continuationCalls[original.id,default:0]+=1
                return try await liveResume(target,expected,original,receipt)
            }
        }
        var pausedBeforeRestart=false,restartCount=0
        services.restart={target,expected in
            if official {
                guard expected.threads.allSatisfy({!$0.active && $0.blocker==nil}),
                      expected.threads.compactMap(\.goal).allSatisfy({$0.status == .paused}) else {
                    throw AppError.message("Every owned task and Goal must pause before server restart")
                }
                pausedBeforeRestart=true;restartCount+=1
            }
            try await liveRestart(target,expected)
        }
        let before=try await services.observe(target)
        if scenario=="official-switch" {
            guard let saved=before.savedAccount,saved != before.serverAccount else {
                throw AppError.message("Different saved and running synthetic accounts required")
            }
        }
        let active=Set(before.threads.filter(\.active).map(\.id)),idle=Set(before.threads.filter{!$0.active}.map(\.id))
        guard active.count==2,idle.count==1 else {throw AppError.message("Two active tasks and one idle control required")}
        var saved:CodexAccountTransitionState?
        let journal=URL(fileURLWithPath:target.home).appendingPathComponent("autoapprove-transition-fixture.json")
        let coordinator=CodexAccountTransitionCoordinator(target:target,services:services,save:{state in
            saved=state
            if official {try JSONEncoder().encode(state).write(to:journal,options:.atomic)}
        })
        for _ in 0..<80 {
            await coordinator.check(loginRequestID:"00000000-0000-4000-8000-000000000235")
            if coordinator.state.phase == .complete {break}
            if coordinator.state.phase == .review,review {break}
            if [.review,.unsupported].contains(coordinator.state.phase),
               !(official && coordinator.state.restartReserved && coordinator.state.phase == .review) {
                throw AppError.message(coordinator.state.detail)
            }
            try await Task.sleep(for:.milliseconds(official ? 400:20))
        }
        guard coordinator.state.phase == (review ? .review:.complete) else {throw AppError.message("Owned continuation did not reach its expected final state: "+coordinator.state.detail)}
        let fresh=try await services.observe(target)
        let wanted=scenario=="skip" ? Set(before.threads.filter{$0.active && $0.goal?.status != .active}.map(\.id)):
            scenario=="completed" ? Set(before.threads.filter{$0.goal?.status == .active}.map(\.id)):active
        if scenario != "blocked" {
            guard Set(fresh.threads.filter(\.active).map(\.id))==wanted else {throw AppError.message("Interrupted Goal and ordinary conversation must both be active after reconnection")}
        }
        guard fresh.threads.filter({idle.contains($0.id)}).allSatisfy({!$0.active && $0.goal?.status == .paused}) else {throw AppError.message("Originally idle paused Goal must stay idle")}
        if official {
            guard pausedBeforeRestart,restartCount==1,fresh.savedAccount==fresh.serverAccount,
                  fresh.serverAccount==before.savedAccount,
                  coordinator.state.verified==3,coordinator.state.resumeResults?.values.filter({$0 == .goal}).count==1,
                  coordinator.state.resumeResults?.values.filter({$0 == .conversation}).count==1 else {throw AppError.message("Every original TUI and exact continuation type must be proved")}
            for original in before.threads {
                guard let now=fresh.threads.first(where:{$0.id==original.id}),now.cwd==original.cwd,now.modelProvider==original.modelProvider else {throw AppError.message("Original conversation configuration changed")}
                if original.active,now.turnID==original.turnID {throw AppError.message("No new continuation turn was started")}
                if let goal=original.goal {
                    guard let retained=now.goal,retained.instanceID==goal.instanceID,retained.createdAt==goal.createdAt,
                          retained.objective==goal.objective,retained.tokenBudget==goal.tokenBudget else {
                        throw AppError.message("The original Goal identity and budget must survive reconnection")
                    }
                }
            }
        }
        let restored=CodexAccountTransitionCoordinator(target:target,state:saved,services:services,save:{saved=$0})
        for _ in 0..<3 {await restored.check(loginRequestID:"00000000-0000-4000-8000-000000000235")}
        if official,restartCount != 1 {throw AppError.message("Restored coordinator must never repeat the restart")}
        if official {
            guard Set(continuationCalls.keys)==active,continuationCalls.values.allSatisfy({$0==1}) else {
                throw AppError.message("Every interrupted conversation must receive exactly one continuation, including after coordinator restoration")
            }
        }
        print("{\"verified\":true,\"resumedWork\":2,\"idleControl\":1}")
    }
}
