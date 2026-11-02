import Foundation
import AutoApproveCore

@main struct AccountTransitionTransportCheck {
    @MainActor static func main() async throws {
        let args = CommandLine.arguments
        let target = CodexAccountTransitionTarget(home: args[1], executable: args[2])
        let mode = args[3], service = CodexAccountTransitionServices.live
        if mode == "reject" {
            do { _ = try await service.observe(target) }
            catch { print("{\"rejected\":true}"); return }
            throw AppError.message("Malformed or unsupported server was accepted")
        }
        let observed = try await service.observe(target)
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
