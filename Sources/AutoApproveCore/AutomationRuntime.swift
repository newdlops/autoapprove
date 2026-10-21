import Foundation

/// Only pending work lives here. Delivery receipts remain with their original
/// transport: cancelling a task cannot retract bytes already sent to a terminal.
@MainActor final class AutomationRuntime {
    private(set) var epochs: [String: UInt64] = [:]
    private(set) var defaultEpoch: UInt64 = 0
    private var nextEpoch: UInt64 = 0
    private var tasks: [String: [UUID: Task<Void, Never>]] = [:]

    func epoch(_ id: String) -> UInt64 { epochs[id] ?? defaultEpoch }
    var sessionIDs: Set<String> { Set(tasks.keys).union(epochs.keys) }

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
        nextEpoch &+= 1
        epochs[id] = nextEpoch
        let pending = tasks.removeValue(forKey: id) ?? [:]
        pending.values.forEach { $0.cancel() }
        return pending.count
    }

    /// Rotate the default too: an old read for a never-reset session must not
    /// become current again when all per-session epochs are discarded.
    @discardableResult func resetAll() -> Int {
        nextEpoch &+= 1; defaultEpoch = nextEpoch
        epochs.removeAll()
        let pending = tasks; tasks.removeAll()
        var count = 0
        for group in pending.values { count += group.count; group.values.forEach { $0.cancel() } }
        return count
    }
    func stop() { resetAll() }
}

public struct AutomationResetResult: Sendable {
    public let sessionCount: Int
    public let cancelledTasks: Int
    public let awaitingDelivery: Bool
    public let automatic: Bool
    public let paused: Bool
    public let allSessions: Bool

    init(sessionCount: Int, cancelledTasks: Int, awaitingDelivery: Bool, automatic: Bool, paused: Bool, allSessions: Bool = false) {
        self.sessionCount = sessionCount; self.cancelledTasks = cancelledTasks
        self.awaitingDelivery = awaitingDelivery; self.automatic = automatic
        self.paused = paused; self.allSessions = allSessions
    }

    public var message: String {
        if allSessions {
            let summary = "이 Mac의 모든 자동화를 초기화했습니다. "
            if awaitingDelivery { return summary + "전달 중인 입력은 중복 전송하지 않고 현재 상태를 다시 감지합니다." }
            if paused { return summary + "전체 일시정지를 유지하며 현재 상태를 다시 감지합니다." }
            return summary + "각 세션의 자동 승인 설정을 유지하며 현재 상태부터 다시 감지합니다."
        }
        if awaitingDelivery {
            return "자동화 대기를 비웠습니다. 전달 중이던 입력을 중복 전송하지 않고 새 화면부터 감지합니다."
        }
        if paused { return "자동화를 초기화했습니다. 전체 일시정지는 유지하며 현재 상태를 다시 감지합니다." }
        if !automatic { return "자동화를 초기화했습니다. 자동 승인은 꺼진 상태로 현재 상태를 다시 감지합니다." }
        return "자동화를 초기화했습니다. 현재 상태부터 다시 감지하고 자동 승인을 이어갑니다."
    }
}
