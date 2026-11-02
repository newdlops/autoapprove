import Foundation
import AutoApproveCore

@main struct AccountContinuationCheck {
    @MainActor static func main() async throws {
        let args=CommandLine.arguments
        var target=CodexAccountTransitionTarget(home:args[1],executable:args[2])
        let scenario=args.count>3 ? args[3]:"normal"
        let official=scenario=="official",review=["blocked","lost-ack"].contains(scenario)
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
        let services=CodexAccountTransitionServices.live
        let before=try await services.observe(target)
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
            if [.review,.unsupported].contains(coordinator.state.phase) {throw AppError.message(coordinator.state.detail)}
            try await Task.sleep(for:.milliseconds(20))
        }
        guard coordinator.state.phase == (review ? .review:.complete) else {throw AppError.message("Owned continuation did not reach its expected final state")}
        let fresh=try await services.observe(target)
        let wanted=scenario=="skip" ? Set(before.threads.filter{$0.active && $0.goal?.status != .active}.map(\.id)):
            scenario=="completed" ? Set(before.threads.filter{$0.goal?.status == .active}.map(\.id)):active
        if scenario != "blocked" {
            guard Set(fresh.threads.filter(\.active).map(\.id))==wanted else {throw AppError.message("Interrupted Goal and ordinary conversation must both be active after reconnection")}
        }
        guard fresh.threads.filter({idle.contains($0.id)}).allSatisfy({!$0.active && $0.goal?.status == .paused}) else {throw AppError.message("Originally idle paused Goal must stay idle")}
        if official {
            guard coordinator.state.verified==3,coordinator.state.resumeResults?.values.filter({$0 == .goal}).count==1,
                  coordinator.state.resumeResults?.values.filter({$0 == .conversation}).count==1 else {throw AppError.message("Every original TUI and exact continuation type must be proved")}
            for original in before.threads {
                guard let now=fresh.threads.first(where:{$0.id==original.id}),now.cwd==original.cwd,now.modelProvider==original.modelProvider else {throw AppError.message("Original conversation configuration changed")}
                if original.active,now.turnID==original.turnID {throw AppError.message("No new continuation turn was started")}
            }
        }
        let restored=CodexAccountTransitionCoordinator(target:target,state:saved,services:services,save:{saved=$0})
        for _ in 0..<3 {await restored.check(loginRequestID:"00000000-0000-4000-8000-000000000235")}
        print("{\"verified\":true,\"resumedWork\":2,\"idleControl\":1}")
    }
}
