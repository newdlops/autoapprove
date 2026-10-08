import Foundation

final class RemoteTerminalChangeSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var observers: [UUID: @Sendable () -> Void] = [:]
    func add(_ callback: @escaping @Sendable () -> Void) -> UUID {
        lock.lock(); defer { lock.unlock() }; let id = UUID(); observers[id] = callback; return id
    }
    func remove(_ id: UUID) { lock.lock(); observers.removeValue(forKey:id); lock.unlock() }
    func notify() { lock.lock(); let callbacks = Array(observers.values); lock.unlock(); callbacks.forEach { $0() } }
    func observe() -> RemoteTerminalObservation { RemoteTerminalObservation(signal:self) }
}

final class RemoteTerminalObservation: @unchecked Sendable {
    private let lock = NSLock(), signal: RemoteTerminalChangeSignal
    private var token: UUID?, pending = true
    private var waiter: (UUID, CheckedContinuation<Void,Never>)?
    private var timeout: Task<Void,Never>?
    fileprivate init(signal: RemoteTerminalChangeSignal) {
        self.signal = signal; token = signal.add { [weak self] in self?.changed() }
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
        let id = UUID()
        await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                lock.lock()
                if pending || Task.isCancelled { pending = false; lock.unlock(); continuation.resume(); return }
                waiter = (id,continuation)
                timeout = Task { [weak self] in
                    do { try await Task.sleep(for:.seconds(max(0.01,interval))) } catch { return }
                    self?.release(id)
                }
                lock.unlock()
            }
        }, onCancel:{ [weak self] in self?.release(id) })
    }
    deinit { if let token { signal.remove(token) }; timeout?.cancel(); waiter?.1.resume() }
}

public enum RemoteTerminalPolling {
    public static func interval(unchanged: Int, responsive: Bool) -> TimeInterval {
        responsive ? 0.15 : min(0.8,0.15 * pow(2,Double(min(3,max(0,unchanged)))))
    }
}
