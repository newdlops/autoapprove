import Foundation

extension RemoteServerEvent {
    static func screen(_ frame: RemoteTerminalFrame, knownRevision: String? = nil) throws -> Data {
        try screen(RemoteTerminalUpdate(frame,knownRevision:knownRevision))
    }
    static func screen(_ update: RemoteTerminalUpdate) throws -> Data {
        let start = RemoteTerminalPerformance.now; var succeeded = false
        defer { RemoteTerminalPerformance.shared.observe(.responseEncoding,elapsed:RemoteTerminalPerformance.now-start,succeeded:succeeded) }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let json = try encoder.encode(update)
        guard json.count <= 2_000_000 else { throw RemoteHTTPError(502, "원본 터미널 화면이 너무 큽니다. 화면 크기를 줄여 다시 연결해주세요.") }
        let data = Data("event: screen\nid: \(update.revision)\ndata: ".utf8) + json + Data("\n\n".utf8)
        succeeded = true; return data
    }
    static func terminalAlive(_ frame: RemoteTerminalFrame) throws -> Data {
        struct Alive: Encodable {
            let streamID: String?, revision: String, sequence: Int?, observedAt: Date
        }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let json = try encoder.encode(Alive(streamID:frame.streamID,revision:frame.revision,sequence:frame.sequence,observedAt:frame.observedAt))
        RemoteTerminalPerformance.shared.increment(.compactPulses)
        return Data("event: alive\ndata: ".utf8) + json + Data("\n\n".utf8)
    }
}

struct RemoteTerminalControls: Equatable {
    let keys: [String]
    let reason: String?
    let streamID: String?
    let nativeState: TerminalNativeDisplay.State?
    let nativeMessage: String?
    let outputReason: String?
    let cursor: TerminalCursor?
    let question: TerminalChoiceQuestion?
    init(_ frame: RemoteTerminalFrame) {
        keys = frame.keys; reason = frame.inputReason; streamID = frame.streamID
        nativeState = frame.nativeDisplay?.state; nativeMessage = frame.nativeDisplay?.message
        outputReason = frame.outputReason; cursor = frame.cursor; question = frame.question
    }
}

/// Synchronizes an emulator's existing session. It never creates, resumes or
/// owns its process. At most one frame read is pending per HTTP connection;
/// slow consumers skip intermediate snapshots rather than accumulate output.
@MainActor final class RemoteTerminalBodyStream: RemoteHTTPBodyStream {
    nonisolated let needsHeartbeat = true
    let initialEvent: Data
    private let read: @MainActor @Sendable () async throws -> RemoteTerminalFrame
    private let waitForChange: (@Sendable (TimeInterval) async -> Void)?
    private let responsive: @MainActor @Sendable () -> Bool
    private var initial: RemoteTerminalFrame?
    private var previous: RemoteTerminalFrame?
    private let delta: Bool
    private let copyEnabled: Bool
    private let compact: Bool
    private let paced: Bool
    private var onCancel: (@MainActor () -> Void)?
    private var revision: String?
    private var controls: RemoteTerminalControls?
    private var emittedAt = Date.distantPast
    private var task: Task<Void, Never>?
    private var waiter: RemoteHTTPStreamCompletion?
    private var cancelled = false
    private var unchanged = 0

    init(initial: RemoteTerminalFrame, emitInitial: Bool = true, delta: Bool = false, copy: Bool = false,
         resume: RemoteTerminalFrame? = nil, compact: Bool = false, paced: Bool = false,
         onCancel: (@MainActor () -> Void)? = nil, waitForChange: (@Sendable (TimeInterval) async -> Void)? = nil,
         responsive: @escaping @MainActor @Sendable () -> Bool = { true }, read: @escaping @MainActor @Sendable () async throws -> RemoteTerminalFrame) throws {
        // A resume basis affects only output encoding. The initial frame above
        // has already passed fresh original/permission checks.
        initialEvent = try RemoteServerEvent.screen(RemoteTerminalUpdate(initial,previous:resume,delta:delta,copy:copy))
        self.initial = emitInitial ? initial : nil; self.read = read; self.delta = delta
        copyEnabled = delta && copy; self.compact = compact; self.paced = paced; self.onCancel = onCancel
        if !emitInitial {
            revision = initial.revision; controls = RemoteTerminalControls(initial); emittedAt = Date(); previous = delta ? initial : nil
        }
        self.waitForChange = waitForChange
        self.responsive = responsive
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
                    else { frame = try await RemoteTerminalReadRecovery.read(self.read) }
                    guard !self.cancelled, !Task.isCancelled else { self.finish(.success(nil)); return }
                    let controls = RemoteTerminalControls(frame)
                    self.unchanged = frame.revision == self.revision && controls == self.controls ? self.unchanged + 1 : 0
                    if frame.revision != self.revision || controls != self.controls || Date().timeIntervalSince(self.emittedAt) >= 2 {
                        let data: Data
                        if self.compact, frame.streamID != nil, frame.revision == self.revision, controls == self.controls {
                            data = try RemoteServerEvent.terminalAlive(frame)
                        }
                        else if self.delta { data = try RemoteServerEvent.screen(RemoteTerminalUpdate(frame,previous:self.previous,delta:true,copy:self.copyEnabled)) }
                        else { data = try RemoteServerEvent.screen(frame,knownRevision:self.revision) }
                        self.revision = frame.revision; self.controls = controls; self.emittedAt = Date()
                        if self.delta { self.previous = frame }
                        self.finish(.success(data)); return
                    }
                    if self.paced { continue } // Shared producer already waits for source changes.
                    // Native emulators expose screen snapshots. The engine shares
                    // their in-flight read/cache across viewers; VS Code's latest
                    // snapshot already arrives on its existing bridge connection.
                    let interval = min(RemoteTerminalPolling.interval(unchanged:self.unchanged,responsive:self.responsive()),
                        max(0.01,2-Date().timeIntervalSince(self.emittedAt)))
                    if let waitForChange = self.waitForChange { await waitForChange(interval) }
                    else { try await Task.sleep(for:.seconds(interval)) }
                }
                self.finish(.success(nil))
            } catch {
                self.finish(self.cancelled || Task.isCancelled ? .success(nil) : .failure(error))
            }
        }
    }
    private func finish(_ result: Result<Data?, Error>) {
        if case .failure = result { onCancel?(); onCancel = nil }
        let completion = waiter; waiter = nil; task = nil; completion?(result)
    }
    nonisolated func cancel() {
        Task { @MainActor [weak self] in
            guard let self, !self.cancelled else { return }
            self.cancelled = true; self.initial = nil; self.previous = nil; self.task?.cancel()
            self.onCancel?(); self.onCancel = nil
            self.finish(.success(nil))
        }
    }
}
