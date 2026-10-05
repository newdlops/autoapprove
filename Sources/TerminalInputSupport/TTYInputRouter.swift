import Foundation
import Darwin

/// One serialized device-write boundary across every authenticated connection.
/// IDs live past the maximum packet deadline, so reconnects cannot replay input.
public final class TTYInputRouter: @unchecked Sendable {
    private let admissionLock = NSLock()
    private let worker = DispatchQueue(label: "local.autoapprove.tty-input.write")
    private var active = false
    private let clock: () -> Double
    private let write: (TTYInputRequest, UInt32) -> TTYInputReply
    private var seen = [UUID: Double]()
    public init(clock: @escaping () -> Double = { TTYInputConfiguration.uptime },
                write: ((TTYInputRequest, UInt32) -> TTYInputReply)? = nil) {
        self.clock = clock; self.write = write ?? { TTYInputRequest.write($0, caller: $1) }
    }
    public func deliver(_ data: Data, caller: UInt32) -> Data {
        guard admit() else { return busyReply }
        defer { finish() }
        return process(data, caller: caller)
    }
    /// Production XPC calls never wait for a device write on a connection's
    /// serial queue. Retain at most one admitted packet across all connections.
    public func deliver(_ data: Data, caller: UInt32, withReply reply: @escaping (Data) -> Void) {
        guard admit() else { reply(busyReply); return }
        let completion = Completion(reply)
        worker.async { [self] in
            let response = process(data, caller: caller)
            finish()
            completion.reply(response)
        }
    }
    private final class Completion: @unchecked Sendable {
        let reply: (Data) -> Void
        init(_ reply: @escaping (Data) -> Void) { self.reply = reply }
    }
    private var busyReply: Data {
        (try? JSONEncoder().encode(TTYInputReply(error: EBUSY, written: 0))) ?? Data("{\"error\":16,\"written\":0}".utf8)
    }
    private func admit() -> Bool {
        guard admissionLock.try() else { return false }
        defer { admissionLock.unlock() }
        guard !active else { return false }
        active = true; return true
    }
    private func finish() { admissionLock.lock(); active = false; admissionLock.unlock() }
    private func process(_ data: Data, caller: UInt32) -> Data {
        let result: TTYInputReply
        if data.count > 20000 || data.isEmpty {
            result = TTYInputReply(error: EINVAL, written: 0)
        } else if let request = try? JSONDecoder().decode(TTYInputRequest.self, from: data) {
            let now = clock(), error = request.error(now: now, caller: caller)
            seen = seen.filter { $0.value > now }
            if error != 0 { result = TTYInputReply(error: error, written: 0) }
            else if seen[request.id] != nil { result = TTYInputReply(error: EALREADY, written: 0) }
            else if seen.count >= 4096 { result = TTYInputReply(error: ENOBUFS, written: 0) }
            else {
                // Reserve before touching the TTY. A partial/failed attempt is
                // consumed too; it must never become an automatic retry.
                seen[request.id] = now + 5
                result = write(request, caller)
            }
        } else { result = TTYInputReply(error: EINVAL, written: 0) }
        return (try? JSONEncoder().encode(result)) ?? Data("{\"error\":22,\"written\":0}".utf8)
    }
}
