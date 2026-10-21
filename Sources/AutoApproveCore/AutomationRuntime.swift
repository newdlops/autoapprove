import Foundation

/// Only pending work lives here. Delivery receipts remain with their original
/// transport: cancelling a task cannot retract bytes already sent to a terminal.
@MainActor final class AutomationRuntime {
    private(set) var epochs: [String: UInt64] = [:]
    private var tasks: [String: [UUID: Task<Void, Never>]] = [:]

    func epoch(_ id: String) -> UInt64 { epochs[id, default: 0] }

    func launch(_ id: String, operation: @escaping @MainActor (UInt64) async -> Void) {
        let token = UUID(), epoch = epoch(id)
        let task = Task { @MainActor [weak self] in
            defer { self?.finish(id, token: token) }
            guard !Task.isCancelled, self?.epoch(id) == epoch else { return }
            await operation(epoch)
        }
        tasks[id, default: [:]][token] = task
    }

    private func finish(_ id: String, token: UUID) {
        tasks[id]?.removeValue(forKey: token)
        if tasks[id]?.isEmpty == true { tasks.removeValue(forKey: id) }
    }

    @discardableResult func reset(_ id: String) -> Int {
        epochs[id, default: 0] &+= 1
        let pending = tasks.removeValue(forKey: id) ?? [:]
        pending.values.forEach { $0.cancel() }
        return pending.count
    }

    func stop() {
        for id in Set(tasks.keys).union(epochs.keys) { reset(id) }
    }
}

public struct AutomationResetResult: Sendable {
    public let sessionCount: Int
    public let cancelledTasks: Int
    public let awaitingDelivery: Bool
    public let automatic: Bool
    public let paused: Bool

    public var message: String {
        if awaitingDelivery {
            return "자동화 대기를 비웠습니다. 전달 중이던 입력을 중복 전송하지 않고 새 화면부터 감지합니다."
        }
        if paused { return "자동화를 초기화했습니다. 전체 일시정지는 유지하며 현재 상태를 다시 감지합니다." }
        if !automatic { return "자동화를 초기화했습니다. 자동 승인은 꺼진 상태로 현재 상태를 다시 감지합니다." }
        return "자동화를 초기화했습니다. 현재 상태부터 다시 감지하고 자동 승인을 이어갑니다."
    }
}
