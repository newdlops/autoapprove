import Foundation
import Network

/// In-flight reads live until completion; completed snapshots expire and removed peers release their work.
@MainActor public final class RemotePeerStateCache {
    private struct Entry {
        let token: UUID
        var endpoint: NWEndpoint
        let task: Task<RemoteNodeView, Never>
        var expires: Date
    }
    private var entries: [String: Entry] = [:]
    public var count: Int { entries.count }
    public init() {}
    public func task(for id: String, endpoint: NWEndpoint, at now: Date = Date()) -> Task<RemoteNodeView, Never>? {
        guard let entry = entries[id], entry.endpoint == endpoint, entry.expires > now else { return nil }
        return entry.task
    }
    public func insert(_ task: Task<RemoteNodeView, Never>, id: String, token: UUID, endpoint: NWEndpoint) {
        entries[id] = Entry(token: token, endpoint: endpoint, task: task, expires: .distantFuture)
    }
    public func finish(id: String, token: UUID, endpoint: NWEndpoint, expires: Date) {
        guard entries[id]?.token == token else { return }
        entries[id]?.endpoint = endpoint; entries[id]?.expires = expires
    }
    public func remove(_ id: String) { entries.removeValue(forKey: id)?.task.cancel() }
    public func removeAll() { entries.values.forEach { $0.task.cancel() }; entries.removeAll() }
    public func prune(liveIDs: Set<String>, at now: Date = Date()) {
        for (id, entry) in entries where !liveIDs.contains(id) || entry.expires <= now { remove(id) }
    }
}
