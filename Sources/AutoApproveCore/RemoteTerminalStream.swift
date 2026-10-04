import Foundation

extension RemoteServerEvent {
    static func screen(_ frame: RemoteTerminalFrame, knownRevision: String? = nil) throws -> Data {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let json = try encoder.encode(RemoteTerminalUpdate(frame, knownRevision: knownRevision))
        guard json.count <= 2_000_000 else { throw RemoteHTTPError(502, "원본 터미널 화면이 너무 큽니다. 화면 크기를 줄여 다시 연결해주세요.") }
        return Data("event: screen\nid: \(frame.revision)\ndata: ".utf8) + json + Data("\n\n".utf8)
    }
}

/// Synchronizes an emulator's existing session. It never creates, resumes or
/// owns its process. At most one frame read is pending per HTTP connection;
/// slow consumers skip intermediate snapshots rather than accumulate output.
@MainActor final class RemoteTerminalBodyStream: RemoteHTTPBodyStream {
    nonisolated let needsHeartbeat = true
    private struct Controls: Equatable {
        let keys: [String]
        let reason: String?
        let streamID: String?
        init(_ frame: RemoteTerminalFrame) { keys = frame.keys; reason = frame.inputReason; streamID = frame.streamID }
    }
    private let read: @MainActor @Sendable () async throws -> RemoteTerminalFrame
    private var initial: RemoteTerminalFrame?
    private var revision: String?
    private var controls: Controls?
    private var emittedAt = Date.distantPast
    private var task: Task<Void, Never>?
    private var waiter: RemoteHTTPStreamCompletion?
    private var cancelled = false

    init(initial: RemoteTerminalFrame, read: @escaping @MainActor @Sendable () async throws -> RemoteTerminalFrame) throws {
        _ = try RemoteServerEvent.screen(initial) // Reject oversized screens before SSE headers.
        self.initial = initial; self.read = read
    }
    deinit { task?.cancel() }
    nonisolated func next(_ completion: @escaping RemoteHTTPStreamCompletion) {
        Task { @MainActor [weak self] in
            guard let self else { completion(.success(nil)); return }
            self.start(completion)
        }
    }
    private func start(_ completion: @escaping RemoteHTTPStreamCompletion) {
        guard !cancelled else { completion(.success(nil)); return }
        guard waiter == nil else { completion(.failure(RemoteHTTPError(500, "중복된 원본 터미널 화면 요청입니다."))); return }
        waiter = completion
        task = Task { [weak self] in
            guard let self else { return }
            do {
                while !self.cancelled, !Task.isCancelled {
                    let frame: RemoteTerminalFrame
                    if let initial = self.initial { self.initial = nil; frame = initial }
                    else { frame = try await self.read() }
                    guard !self.cancelled, !Task.isCancelled else { self.finish(.success(nil)); return }
                    let controls = Controls(frame)
                    if frame.revision != self.revision || controls != self.controls || Date().timeIntervalSince(self.emittedAt) >= 2 {
                        let data = try RemoteServerEvent.screen(frame, knownRevision: self.revision)
                        self.revision = frame.revision; self.controls = controls; self.emittedAt = Date()
                        self.finish(.success(data)); return
                    }
                    // Native emulators expose screen snapshots. The engine shares
                    // their in-flight read/cache across viewers; VS Code's latest
                    // snapshot already arrives on its existing bridge connection.
                    try await Task.sleep(nanoseconds: 150_000_000)
                }
                self.finish(.success(nil))
            } catch {
                self.finish(self.cancelled || Task.isCancelled ? .success(nil) : .failure(error))
            }
        }
    }
    private func finish(_ result: Result<Data?, Error>) {
        let completion = waiter; waiter = nil; task = nil; completion?(result)
    }
    nonisolated func cancel() {
        Task { @MainActor [weak self] in
            guard let self, !self.cancelled else { return }
            self.cancelled = true; self.initial = nil; self.task?.cancel()
            self.finish(.success(nil))
        }
    }
}
