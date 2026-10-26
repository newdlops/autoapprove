import Foundation
import Network

/// One budget for discovery and metadata checks, independent of browser and input traffic.
actor RemoteDiscoveryTraffic {
    static let shared = RemoteDiscoveryTraffic()
    private struct Waiter {
        let id: UUID
        let known: Bool
        let continuation: CheckedContinuation<Void,Error>
    }
    private var active = 0
    private var blindActive = 0
    private var nextStart: TimeInterval = 0
    private var waiters: [Waiter] = []
    private var wake: (id: UUID, task: Task<Void,Never>)?
    private var lastBlindStart = -TimeInterval.infinity

    private func enter(known: Bool) async throws {
        try Task.checkCancellation()
        let now = ProcessInfo.processInfo.systemUptime
        if waiters.isEmpty, active < 8, known || blindActive < 6, now >= nextStart {
            active += 1; nextStart = now+0.05
            if !known { blindActive += 1; lastBlindStart = now }
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void,Error>) in
                guard !Task.isCancelled else { continuation.resume(throwing:CancellationError()); return }
                waiters.append(Waiter(id:id,known:known,continuation:continuation))
                drain()
            }
        }, onCancel: { Task { await self.cancel(id) } })
    }
    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where:{$0.id == id}) else { return }
        waiters.remove(at:index).continuation.resume(throwing:CancellationError())
        drain()
    }
    private func drain() {
        guard active < 8, !waiters.isEmpty else { wake?.task.cancel(); wake = nil; return }
        let now = ProcessInfo.processInfo.systemUptime
        if now < nextStart {
            guard wake == nil else { return }
            let delay = nextStart-now
            // One deadline for the shared start budget, never one timer per
            // waiting peer. Slot release and cancellation re-evaluate directly.
            let id = UUID()
            let task = Task { [weak self] in
                do { try await Task.sleep(for:.seconds(delay)) } catch { return }
                guard !Task.isCancelled else { return }; await self?.wakeUp(id)
            }
            wake = (id,task)
            return
        }
        wake?.task.cancel(); wake = nil
        let known = waiters.firstIndex(where:{$0.known})
        let blind = blindActive < 6 ? waiters.firstIndex(where:{!$0.known}) : nil
        // Reserve two sockets for saved identities, and give a queued subnet
        // probe an explicit turn even when known-peer checks keep arriving.
        guard let index = blind.flatMap({ known == nil || now-lastBlindStart >= 0.5 ? $0 : nil }) ?? known ?? blind else { return }
        let waiter = waiters.remove(at:index)
        active += 1; nextStart = now+0.05
        if !waiter.known { blindActive += 1; lastBlindStart = now }
        waiter.continuation.resume()
        drain()
    }
    private func wakeUp(_ id: UUID) {
        guard wake?.id == id else { return }
        wake = nil; drain()
    }
    func get(_ endpoint: NWEndpoint, path: String, expectedID: String? = nil, timeout: TimeInterval = 1) async throws -> RemoteHTTPResponse {
        let known = expectedID != nil
        try await enter(known:known)
        defer { active -= 1; if !known { blindActive -= 1 }; drain() }
        try Task.checkCancellation()
        // A later scheduled probe is preferable to hidden retries during discovery.
        return try await RemoteHTTPExchange(endpoint: endpoint, path: path, method: "GET", body: Data(), expectedNodeID: expectedID, timeout: timeout, retryReads: false).run()
    }
    deinit { wake?.task.cancel() }
}

actor RemoteDashboardTraffic {
    static let shared = RemoteDashboardTraffic()
    private struct Waiter {
        let id: UUID
        let foreground: Bool
        let continuation: CheckedContinuation<Void,Error>
    }
    private var active = 0
    private var waiters: [Waiter] = []
    private func enter(foreground: Bool) async throws {
        try Task.checkCancellation()
        if waiters.isEmpty, active < (foreground ? 4 : 3) { active += 1; return }
        let id = UUID()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void,Error>) in
                guard !Task.isCancelled else { continuation.resume(throwing:CancellationError()); return }
                waiters.append(Waiter(id:id,foreground:foreground,continuation:continuation))
                drain()
            }
        }, onCancel: { Task { await self.cancel(id) } })
    }
    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where:{$0.id == id}) else { return }
        waiters.remove(at:index).continuation.resume(throwing:CancellationError())
        drain()
    }
    private func drain() {
        while let index = waiters.firstIndex(where:{active < ($0.foreground ? 4 : 3)}) {
            active += 1
            waiters.remove(at:index).continuation.resume()
        }
    }
    func read(foreground: Bool = false, _ operation: @Sendable () async throws -> RemoteHTTPResponse) async throws -> RemoteHTTPResponse {
        // A bookmarked/selected Mac cannot queue behind three dead inventories.
        // The overall four-read budget remains unchanged.
        try await enter(foreground:foreground); defer { active -= 1; drain() }
        try Task.checkCancellation()
        return try await operation()
    }
}
