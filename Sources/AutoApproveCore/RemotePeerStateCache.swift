import Foundation
import Network

/// In-flight reads live until completion; completed snapshots expire and removed peers release their work.
@MainActor public final class RemotePeerStateCache {
    private struct Entry {
        let token: UUID
        var endpoint: NWEndpoint
        let task: Task<RemoteNodeView, Never>
        var expires: Date
        var value: RemoteNodeView?
    }
    private var entries: [String: Entry] = [:]
    private struct Waiter {
        let continuation: CheckedContinuation<Void, Never>
        let timeout: Task<Void, Never>
    }
    private var waiters: [UUID: Waiter] = [:]
    public private(set) var revision = UUID()
    var onChange: (() -> Void)?
    public var count: Int { entries.count }
    func contains(_ id: String) -> Bool { entries[id] != nil }
    public init() {}
    public func task(for id: String, endpoint: NWEndpoint, at now: Date = Date()) -> Task<RemoteNodeView, Never>? {
        guard let entry = entries[id], entry.endpoint == endpoint, entry.expires > now else { return nil }
        return entry.task
    }
    public func insert(_ task: Task<RemoteNodeView, Never>, id: String, token: UUID, endpoint: NWEndpoint, preservingValue: Bool = false) {
        let retained = preservingValue && entries[id]?.endpoint == endpoint ? entries[id]?.value : nil
        if let previous = entries[id], previous.task != task { previous.task.cancel() }
        entries[id] = Entry(token: token, endpoint: endpoint, task: task, expires: .distantFuture, value:retained)
        changed()
    }
    /// Async readers must still own the reservation before mutating shared
    /// validators. A replaced/cancelled read may finish after its successor.
    public func isCurrent(id: String, token: UUID) -> Bool { entries[id]?.token == token }
    public func finish(id: String, token: UUID, endpoint: NWEndpoint, expires: Date, value: RemoteNodeView? = nil) {
        guard entries[id]?.token == token else { return }
        entries[id]?.endpoint = endpoint; entries[id]?.expires = expires; entries[id]?.value = value
        changed()
    }
    public func value(for id: String, endpoint: NWEndpoint, at now: Date = Date()) -> RemoteNodeView? {
        guard let entry = entries[id], entry.endpoint == endpoint, entry.expires > now else { return nil }
        return entry.value
    }
    public func remove(_ id: String) {
        guard let entry = entries.removeValue(forKey: id) else { return }
        entry.task.cancel(); changed()
    }
    public func removeAll() { entries.values.forEach { $0.task.cancel() }; entries.removeAll(); changed() }
    public func prune(liveIDs: Set<String>, at now: Date = Date()) {
        for (id, entry) in entries where !liveIDs.contains(id) || entry.expires <= now { remove(id) }
    }
    private func changed() {
        revision = UUID()
        onChange?()
        let current = waiters; waiters.removeAll()
        for waiter in current.values { waiter.timeout.cancel(); waiter.continuation.resume() }
    }
    private func releaseWaiter(_ id: UUID) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiter.timeout.cancel(); waiter.continuation.resume()
    }
    /// A revision closes the check/subscribe race. Cancelling one browser wait
    /// releases only that continuation, never the shared source read.
    public func waitForChange(after revision: UUID, timeout interval: TimeInterval) async {
        guard interval.isFinite, interval > 0 else { return }
        let id = UUID()
        await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                guard self.revision == revision, !Task.isCancelled else { continuation.resume(); return }
                let timeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(min(1, interval))) } catch { return }
                    self?.releaseWaiter(id)
                }
                waiters[id] = Waiter(continuation: continuation, timeout: timeout)
            }
        }, onCancel: { [weak self] in Task { @MainActor in self?.releaseWaiter(id) } })
    }
}
