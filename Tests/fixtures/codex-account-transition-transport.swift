import Foundation
import AutoApproveCore

@main struct AccountTransitionTransportCheck {
    @MainActor static func main() async throws {
        let args = CommandLine.arguments
        var target = CodexAccountTransitionTarget(home: args[1], executable: args[2])
        let mode = args[3], service = CodexAccountTransitionServices.live
        if mode == "official-lifecycle" || mode == "official-recovery" {
            let recovery=mode == "official-recovery"
            guard target.home.hasPrefix("/private/tmp/aa-account-real-cli-"), args.count == 6,
                  let first=Int32(args[4]),let second=Int32(args[5]),first != second else {throw AppError.message("Owned temporary official fixture required")}
            let pids:Set<Int32>=[first,second]
            let records=try ProcessDiscovery.read().filter{pids.contains($0.pid)}
            let discovered=try await CodexAccountTransitionTarget.discover(records)
            let canonical=URL(fileURLWithPath:target.home).standardizedFileURL.resolvingSymlinksInPath().path
            guard discovered.count==1,discovered[0].home==canonical,discovered[0].witnesses.count==2 else {throw AppError.message("Owned TUI identity or common server missing")}
            target=discovered[0]
            let before=try await service.observe(target)
            guard (recovery ? before.threads.count>=2:before.threads.count==2),(recovery ? before.threads.allSatisfy(\.active):before.threads.allSatisfy({!$0.active && $0.blocker==nil})),target.witnesses.allSatisfy({$0.threadID==nil}) else {throw AppError.message("Expected owned conversations in the fixture's exact activity state")}
            let journal=URL(fileURLWithPath:target.home).appendingPathComponent("autoapprove-transition-fixture.json")
            let coordinator=CodexAccountTransitionCoordinator(target:target,services:service,save:{state in try JSONEncoder().encode(state).write(to:journal,options:.atomic)})
            for _ in 0..<100 {
                await coordinator.check(loginRequestID:recovery ? "00000000-0000-4000-8000-000000000234":nil)
                if coordinator.state.phase == .complete {
                    guard coordinator.state.verified==2 else {throw AppError.message("Not every owned TUI reconnected")}
                    if recovery {guard coordinator.state.reservations.count==before.threads.count else {throw AppError.message("Every original active conversation must be stopped")}}
                    print("{\"verified\":true,\"officialLifecycle\":true,\"originalProcesses\":2,\"originalConversations\":\(before.threads.count),\"withoutRolloutWitnesses\":true}");return
                }
                if [.review,.unsupported].contains(coordinator.state.phase) {throw AppError.message(coordinator.state.detail)}
                try await Task.sleep(for:.milliseconds(250))
            }
            throw AppError.message("Owned official lifecycle did not finish")
        }
        if mode == "reject" {
            do { _ = try await service.observe(target) }
            catch { print("{\"rejected\":true}"); return }
            throw AppError.message("Malformed or unsupported server was accepted")
        }
        let observed = try await service.observe(target)
        if mode == "official-empty" {
            guard observed.threads.count == 2, observed.threads.allSatisfy({ !$0.active && $0.turnID == nil && $0.blocker == nil }) else {
                throw AppError.message("Official empty conversations did not pass every idle barrier")
            }
            print("{\"officialEmptyThreads\":2,\"verified\":true}"); return
        }
        guard observed.savedAccount != nil, observed.savedAccount != observed.serverAccount,
              observed.threads.count == 2, Set(observed.threads.map(\.id)).count == 2 else {
            throw AppError.message("Account or complete loaded membership differs")
        }
        if mode == "cancel-interrupt" {
            try Data("delay".utf8).write(to: URL(fileURLWithPath: target.home).appendingPathComponent("delay-version"))
            let thread = observed.threads.first(where: \.active)!
            let task = Task { try await service.interrupt(target, observed.serverID, thread.id, thread.turnID!) }
            try await Task.sleep(for: .milliseconds(50)); task.cancel()
            do { try await task.value }
            catch is CancellationError { print("{\"cancelled\":true}"); return }
            throw AppError.message("Cancelled inspection still sent an interrupt")
        } else if mode == "quiesce" || mode == "queued-worker" {
            let thread=observed.threads.first(where:{$0.active || $0.blocker != nil})!
            if mode == "queued-worker" {guard ["활성 Goal","백그라운드 작업"].contains(thread.blocker ?? "") else {throw AppError.message("Queue masked a worker that must stop")}}
            try await service.interrupt(target,observed.serverID,thread.id,thread.turnID!)
            if mode == "queued-worker" {let after=try await service.observe(target);guard after.threads.first(where:{$0.id==thread.id})?.blocker=="대기 입력" else {throw AppError.message("Queued message was lost during work cleanup")}}
        } else if mode == "reject-interrupt" {
            let thread=observed.threads.first(where: \.active)!
            do {try await service.interrupt(target,observed.serverID,thread.id,thread.turnID!)}
            catch {print("{\"rejected\":true}");return}
            throw AppError.message("Unverified interrupt completion was accepted")
        } else if mode == "interrupt" {
            let thread = observed.threads.first(where: \.active)!
            try await service.interrupt(target, observed.serverID, thread.id, thread.turnID!)
        } else if mode == "restart" {
            try await service.restart(target, observed)
        } else if mode == "block" {
            guard observed.threads.contains(where: { $0.blocker != nil }) else { throw AppError.message("Missing barrier") }
            do { try await service.restart(target, observed) }
            catch { print("{\"blocked\":true}"); return }
            throw AppError.message("Blocked server was restarted")
        }
        print("{\"verified\":true}")
    }
}
