import Foundation

/// Notification bookkeeping only. These callbacks wake a fresh original read;
/// the pool never stores text, permissions or an input authorization.
fileprivate final class TerminalObservationCallbacks: @unchecked Sendable {
    private let lock = NSLock()
    private var callbacks: [UUID:@Sendable () -> Void] = [:]
    func add(_ callback: @escaping @Sendable () -> Void) -> UUID {
        lock.lock(); defer { lock.unlock() }
        let id = UUID(); callbacks[id] = callback; return id
    }
    func remove(_ id: UUID) { lock.lock(); callbacks.removeValue(forKey:id); lock.unlock() }
    func notify() {
        lock.lock(); let current = Array(callbacks.values); lock.unlock()
        current.forEach { $0() }
    }
}

fileprivate final class TerminalObservationSource<Handle: AnyObject>: @unchecked Sendable {
    let handle: Handle
    let callbacks: TerminalObservationCallbacks
    init(handle: Handle, callbacks: TerminalObservationCallbacks) { self.handle = handle; self.callbacks = callbacks }
}

final class TerminalObservationLease<Handle: AnyObject>: @unchecked Sendable {
    private let source: TerminalObservationSource<Handle>
    private let token: UUID
    fileprivate init(source: TerminalObservationSource<Handle>, changed: @escaping @Sendable () -> Void) {
        self.source = source; token = source.callbacks.add(changed)
    }
    deinit { source.callbacks.remove(token) }
}

@MainActor final class TerminalObservationPool<Identity: Equatable, Handle: AnyObject> {
    private var identity: Identity?
    private weak var source: TerminalObservationSource<Handle>?

    func subscribe(identity: Identity?, canReuse: (Handle) -> Bool = { _ in true },
                   make: (@escaping @Sendable () -> Void) -> Handle?,
                   changed: @escaping @Sendable () -> Void) -> TerminalObservationLease<Handle>? {
        // One weak slot: the last subscriber owns teardown, and a Terminal
        // restart or an unavailable launch identity cannot reuse registration.
        if let identity, identity == self.identity, let source, canReuse(source.handle) {
            return TerminalObservationLease(source:source,changed:changed)
        }
        let callbacks = TerminalObservationCallbacks()
        guard let handle = make({ callbacks.notify() }) else { return nil }
        let source = TerminalObservationSource(handle:handle,callbacks:callbacks)
        if let identity { self.identity = identity; self.source = source }
        return TerminalObservationLease(source:source,changed:changed)
    }
}
