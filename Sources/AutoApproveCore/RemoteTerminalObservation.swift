import Foundation

final class RemoteTerminalChangeSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var observers: [UUID: @Sendable () -> Void] = [:]
    private var value: UInt64 = 0
    var revision: UInt64 { lock.lock(); defer { lock.unlock() }; return value }
    var hasObservers: Bool { lock.lock(); defer { lock.unlock() }; return !observers.isEmpty }
    func add(_ callback: @escaping @Sendable () -> Void) -> UUID {
        lock.lock(); defer { lock.unlock() }; let id = UUID(); observers[id] = callback; return id
    }
    func remove(_ id: UUID) { lock.lock(); observers.removeValue(forKey:id); lock.unlock() }
    func notify() {
        lock.lock()
        value &+= 1
        guard !observers.isEmpty else { lock.unlock(); return }
        let callbacks = Array(observers.values)
        lock.unlock()
        callbacks.forEach { $0() }
    }
    func observe() -> RemoteTerminalObservation { RemoteTerminalObservation(signal:self) }
}

final class RemoteTerminalObservation: @unchecked Sendable {
    private let lock = NSLock(), signal: RemoteTerminalChangeSignal
    private var token: UUID?, pending = true
    private var waiter: (UUID, CheckedContinuation<Void,Never>)?
    private var timeout: Task<Void,Never>?
    private var cursorObservation: TerminalCursorObservation?
    fileprivate init(signal: RemoteTerminalChangeSignal) {
        self.signal = signal; token = signal.add { [weak self] in self?.changed() }
    }
    @MainActor func observeNativeCursor(_ changed: @escaping @Sendable () -> Void) {
        // Send the prepared first frame before discovering native AX elements.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            self?.cursorObservation = TerminalCursorObservation(changed: changed)
        }
    }
    private func changed() {
        lock.lock(); pending = true; let current = waiter; waiter = nil
        let timer = timeout; timeout = nil; lock.unlock()
        timer?.cancel(); current?.1.resume()
    }
    private func release(_ id: UUID) {
        lock.lock(); let current = waiter?.0 == id ? waiter : nil
        if current != nil { waiter = nil; timeout?.cancel(); timeout = nil }
        lock.unlock(); current?.1.resume()
    }
    func waitForChange(timeout interval: TimeInterval) async {
        await waitForChange(timeout: interval as TimeInterval?)
    }
    /// Park until a source changes or the owning task is cancelled. This is
    /// used for inactive pollers whose work can only become due after an
    /// explicit state-change signal; a periodic timeout would only wake them
    /// to confirm that they still have nothing to do.
    func waitForChange() async {
        await waitForChange(timeout: nil)
    }
    private func waitForChange(timeout interval: TimeInterval?) async {
        let id = UUID()
        await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                lock.lock()
                if pending || Task.isCancelled { pending = false; lock.unlock(); continuation.resume(); return }
                waiter = (id,continuation)
                if let interval {
                    timeout = Task { [weak self] in
                        do { try await Task.sleep(for:.seconds(max(0.01,interval))) } catch { return }
                        self?.release(id)
                    }
                } else {
                    timeout = nil
                }
                lock.unlock()
            }
        }, onCancel:{ [weak self] in self?.release(id) })
    }
    deinit { if let token { signal.remove(token) }; timeout?.cancel(); waiter?.1.resume() }
}

public enum RemoteTerminalPolling {
    public static func interval(unchanged: Int, responsive: Bool) -> TimeInterval {
        guard !responsive else { return 0.15 }
        // Source-change signals deliver changed screens immediately. Allow one
        // short confirmation after a change, then wait for the same two-second
        // cadence as the compact liveness event instead of rereading a stable
        // terminal at 0.15/0.3/0.6-second intervals inside one heartbeat window.
        return unchanged <= 0 ? 0.5 : 2
    }

    /// Preserve the configured start-to-start cadence when reads are fast. If a
    /// slow source exceeds that cadence, wait one interval after completion
    /// instead of immediately issuing another expensive native read.
    public static func delayAfterRead(interval: TimeInterval, elapsed: TimeInterval) -> TimeInterval {
        let cadence = interval.isFinite ? max(0.1, interval) : 0.1
        guard elapsed.isFinite, elapsed >= 0 else { return cadence }
        return elapsed >= cadence ? cadence : max(0.1, cadence - elapsed)
    }

    /// Active CLI screens stay responsive immediately after output changes, then
    /// ease back to fewer native terminal reads once the same frame is stable.
    /// Approval, interruption and user-input states use their own faster cadence.
    public static func activeScreenInterval(unchangedReads: Int) -> TimeInterval {
        let stableReads = min(4, max(0, unchangedReads - 2))
        return 1.5 + Double(stableReads) * 0.25
    }

    /// Monitor cadence of one session. These are the former host-wide values,
    /// now applied per session: input in flight 0.35 s, manual or paused 4 s,
    /// approval, a question or a model wait 0.5 s, an unsent composer draft
    /// 2 s, interruption 2 s, active output 1.5-2.5 s and idle 3 s.
    public static func sessionInterval(priorityInput: Bool, automatic: Bool, awaitingAnswer: Bool,
                                       composerDraft: Bool = false, interrupted: Bool, active: Bool,
                                       unchangedReads: Int) -> TimeInterval {
        if priorityInput { return 0.35 }
        if !automatic { return 4 }
        if awaitingAnswer { return 0.5 }
        if composerDraft || interrupted { return 2 }
        return active ? activeScreenInterval(unchangedReads: unchangedReads) : 3
    }

    /// Sessions whose own cadence is due. A session due within a quarter of
    /// its interval (at most 0.25 s) joins this pass, so neighbouring cadences
    /// share one native read instead of waking the poller twice.
    public static func dueTargets(_ ids: [String], intervals: [String: TimeInterval],
                                  lastRead: [String: TimeInterval], now: TimeInterval) -> [String] {
        ids.filter { id in
            guard let last = lastRead[id] else { return true }
            let interval = intervals[id] ?? 3
            return now - last >= interval - min(0.25, interval / 4)
        }
    }

    package static func monitorBatch(_ ids: [String], pending: Set<String>, intervals: [String: TimeInterval],
                                     lastRead: [String: TimeInterval], now: TimeInterval, limit: Int) -> [String] {
        let due = pending.union(dueTargets(ids, intervals: intervals, lastRead: lastRead, now: now))
        let candidates = ids.filter { due.contains($0) }
        guard candidates.count > limit else { return candidates }
        return Array(candidates.sorted {
            (lastRead[$0] ?? -.infinity, $0) < (lastRead[$1] ?? -.infinity, $1)
        }.prefix(limit))
    }

    /// Time until the next session becomes due, kept between 0.1 and 8 s.
    public static func nextReadDelay(_ ids: [String], intervals: [String: TimeInterval],
                                     lastRead: [String: TimeInterval], now: TimeInterval) -> TimeInterval {
        let next = ids.map { id -> TimeInterval in
            guard let last = lastRead[id] else { return 0 }
            return last + (intervals[id] ?? 3) - now
        }.min() ?? 8
        return min(8, max(0.1, next))
    }
}
