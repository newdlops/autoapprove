import Foundation

/// One read-only producer per original/view. Subscribers retain only the latest
/// frame; a slow HTTP writer cannot queue snapshots or delay another viewer.
@MainActor final class RemoteTerminalFeeds {
    struct Key: Hashable { let session: String; let window: Bool }
    private var feeds: [Key: RemoteTerminalFeed] = [:]
    private var history: [(key: Key, frame: RemoteTerminalFrame, at: TimeInterval, cost: Int)] = []
    private var expiry: Task<Void, Never>?
    private static let lifetime: TimeInterval = 30
    private static let historyLimit = 4 * 1024 * 1024

    func subscribe(key: Key, initial: @escaping @MainActor () async throws -> RemoteTerminalFrame,
                   observation: @escaping @MainActor () throws -> (@Sendable (TimeInterval) async -> Void),
                   responsive: @escaping @MainActor () -> Bool,
                   read: @escaping @MainActor () async throws -> RemoteTerminalFrame) async throws -> RemoteTerminalSubscription {
        prune()
        let feed: RemoteTerminalFeed
        if let existing = feeds[key] { feed = existing }
        else {
            // The HTTP server already bounds active streams. Also bound idle
            // producers retained during a short phone background transition.
            for oldKey in Array(feeds.keys) where feeds[oldKey]?.isIdle == true { feeds.removeValue(forKey:oldKey) }
            guard feeds.count < 12 else { throw RemoteHTTPError(503,"터미널 연결이 많습니다. 사용하지 않는 화면을 닫고 다시 연결해주세요.") }
            feed = RemoteTerminalFeed(initial:initial,observation:observation,responsive:responsive,read:read)
            feed.record = { [weak self] frame in self?.remember(frame,key:key) }
            feed.failed = { [weak self, weak feed] in
                guard let self, self.feeds[key] === feed else { return }
                self.feeds.removeValue(forKey:key)
                self.history.removeAll { $0.key == key }
            }
            feeds[key] = feed
        }
        return try await feed.subscribe()
    }

    func base(key: Key, revision: String?, stream: String?, current: RemoteTerminalFrame) -> RemoteTerminalFrame? {
        prune()
        guard revision != nil || stream != nil else { return nil }
        guard !key.window, let revision, revision.utf8.count <= 512,
              let stream, !stream.isEmpty, stream.utf8.count <= 512, stream == current.streamID else {
            RemoteTerminalPerformance.shared.increment(.resumeMisses); return nil
        }
        let frame = history.last { $0.key == key && $0.frame.revision == revision && $0.frame.streamID == stream }?.frame
        RemoteTerminalPerformance.shared.increment(frame == nil ? .resumeMisses : .resumeHits)
        return frame
    }

    private func remember(_ frame: RemoteTerminalFrame, key: Key) {
        guard !key.window, frame.nativeDisplay == nil, let stream = frame.streamID, !stream.isEmpty else { return }
        prune()
        history.removeAll { $0.key == key && ($0.frame.streamID != stream || $0.frame.revision == frame.revision) }
        // Conservative retained-content accounting, including attributed runs
        // and option strings. No extra JSON encoding in the hot producer loop.
        var cost = frame.screen.utf8.count + 4096
        cost += (frame.appearance?.runs.count ?? 0) * 256
        let controls: [String?] = [frame.sessionID,frame.revision,frame.streamID,frame.inputReason,frame.outputReason]
        for value in controls { cost += value?.utf8.count ?? 0 }
        for key in frame.keys { cost += key.utf8.count }
        if let question = frame.question {
            cost += question.id.utf8.count; cost += question.question.utf8.count
            for option in question.options { cost += option.utf8.count }
            cost += question.reply?.answer.utf8.count ?? 0
            cost += question.reply?.message.utf8.count ?? 0
            cost += question.reply?.queueID?.utf8.count ?? 0
        }
        if cost <= Self.historyLimit {
            while history.filter({$0.key == key}).count >= 6 {
                if let index = history.firstIndex(where:{$0.key == key}) { history.remove(at:index) }
            }
            history.append((key,frame,RemoteTerminalPerformance.now,cost))
            while history.reduce(0,{$0+$1.cost}) > Self.historyLimit { history.removeFirst() }
        }
        if expiry == nil {
            expiry = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for:.seconds(Self.lifetime)) } catch { return }
                    guard let self else { return }; self.prune()
                    if self.history.isEmpty { self.expiry = nil; return }
                }
            }
        }
    }
    private func prune() {
        let now = RemoteTerminalPerformance.now
        history.removeAll { now-$0.at >= Self.lifetime }
    }
    func stop() {
        expiry?.cancel(); expiry = nil
        let current = Array(feeds.values); feeds.removeAll(); history.removeAll()
        current.forEach { $0.stop() }
    }
    deinit { expiry?.cancel() }
}

@MainActor private final class RemoteTerminalFeed {
    private struct Subscriber {
        var sequence = -1
        var waiter: CheckedContinuation<RemoteTerminalFrame, Error>?
    }
    private var subscribers: [UUID: Subscriber] = [:]
    private var latest: RemoteTerminalFrame?
    private var initialTask: (id: UUID, task: Task<RemoteTerminalFrame, Error>)?
    private var task: Task<Void, Never>?
    private var failure: Error?
    private var wait: (@Sendable (TimeInterval) async -> Void)?
    private let initialRead: @MainActor () async throws -> RemoteTerminalFrame
    private let makeObservation: @MainActor () throws -> (@Sendable (TimeInterval) async -> Void)
    private let responsive: @MainActor () -> Bool
    private let read: @MainActor () async throws -> RemoteTerminalFrame
    var record: ((RemoteTerminalFrame) -> Void)?
    var failed: (() -> Void)?
    var isIdle: Bool { subscribers.isEmpty }
    init(initial: @escaping @MainActor () async throws -> RemoteTerminalFrame,
         observation: @escaping @MainActor () throws -> (@Sendable (TimeInterval) async -> Void),
         responsive: @escaping @MainActor () -> Bool, read: @escaping @MainActor () async throws -> RemoteTerminalFrame) {
        initialRead = initial; makeObservation = observation; self.responsive = responsive; self.read = read
    }
    func subscribe() async throws -> RemoteTerminalSubscription {
        if !subscribers.isEmpty { RemoteTerminalPerformance.shared.increment(.sharedSubscribers) }
        let id = UUID(); subscribers[id] = Subscriber()
        do {
            let pending: (id: UUID, task: Task<RemoteTerminalFrame, Error>)
            if let initialTask { pending = initialTask }
            else {
                let token = UUID(), operation = initialRead
                let task = Task { @MainActor [weak self] in
                    // A completed permission check must not authorize a later
                    // subscriber that happens to arrive before an actor hop.
                    defer { if self?.initialTask?.id == token { self?.initialTask = nil } }
                    return try await RemoteTerminalReadRecovery.read(operation)
                }
                pending = (token,task); initialTask = pending
            }
            let frame = try await withTaskCancellationHandler(operation:{ try await pending.task.value },onCancel:{
                Task { @MainActor [weak self] in self?.remove(id) }
            })
            try Task.checkCancellation()
            guard subscribers[id] != nil, failure == nil else { throw failure ?? CancellationError() }
            publish(frame)
            subscribers[id]?.sequence = frame.sequence ?? -1
            if task == nil { try start() }
            return RemoteTerminalSubscription(feed:self,id:id,initial:frame)
        } catch { remove(id); throw error }
    }
    private func start() throws {
        wait = try makeObservation()
        RemoteTerminalPerformance.shared.increment(.liveProducers)
        task = Task { [weak self] in
            guard let self else { return }
            var unchanged = 0
            do {
                while !Task.isCancelled, !self.subscribers.isEmpty {
                    let began = RemoteTerminalPerformance.now
                    let previous = self.latest
                    RemoteTerminalPerformance.shared.increment(.liveReads)
                    let frame = try await RemoteTerminalReadRecovery.read(self.read)
                    try Task.checkCancellation()
                    guard !self.subscribers.isEmpty else { return }
                    unchanged = previous.map { RemoteTerminalControls($0) == RemoteTerminalControls(frame) && $0.revision == frame.revision } == true ? unchanged+1 : 0
                    self.publish(frame)
                    if let wait = self.wait { await wait(RemoteTerminalPolling.interval(unchanged:unchanged,responsive:self.responsive())) }
                    // Coalesce bursts of unrelated/native change notifications
                    // when they keep yielding the same screen and controls.
                    // Include read time, so a real slow source adds no delay.
                    let remaining = 0.05-(RemoteTerminalPerformance.now-began)
                    if unchanged > 0, remaining > 0 { try await Task.sleep(for:.seconds(remaining)) }
                }
            } catch {
                guard !Task.isCancelled else { return }
                self.failure = error
                let waiting = self.subscribers.values.compactMap(\.waiter)
                for id in Array(self.subscribers.keys) { self.subscribers[id]?.waiter = nil }
                waiting.forEach { $0.resume(throwing:error) }
                self.latest = nil; self.wait = nil; self.task = nil; self.failed?()
            }
        }
    }
    private func publish(_ frame: RemoteTerminalFrame) {
        guard !subscribers.isEmpty, (frame.sequence ?? 0) >= (latest?.sequence ?? 0) else { return }
        latest = frame; record?(frame)
        for id in Array(subscribers.keys) {
            guard let subscriber = subscribers[id], let waiter = subscriber.waiter,
                  (frame.sequence ?? 0) > subscriber.sequence else { continue }
            subscribers[id]?.waiter = nil; subscribers[id]?.sequence = frame.sequence ?? 0
            waiter.resume(returning:frame)
        }
    }
    fileprivate func next(_ id: UUID) async throws -> RemoteTerminalFrame {
        try await withTaskCancellationHandler(operation:{
            try Task.checkCancellation()
            guard let subscriber = subscribers[id] else { throw CancellationError() }
            if let failure { throw failure }
            guard subscriber.waiter == nil else { throw RemoteHTTPError(500,"중복된 터미널 감시 요청입니다.") }
            if let latest, (latest.sequence ?? 0) > subscriber.sequence {
                subscribers[id]?.sequence = latest.sequence ?? 0; return latest
            }
            return try await withCheckedThrowingContinuation { subscribers[id]?.waiter = $0 }
        },onCancel:{ Task { @MainActor [weak self] in self?.remove(id) } })
    }
    fileprivate func remove(_ id: UUID) {
        subscribers.removeValue(forKey:id)?.waiter?.resume(throwing:CancellationError())
        if subscribers.isEmpty {
            task?.cancel(); task = nil; initialTask?.task.cancel(); initialTask = nil
            latest = nil; wait = nil
        }
    }
    func stop() {
        failure = CancellationError()
        for id in Array(subscribers.keys) { remove(id) }
    }
    deinit { task?.cancel(); initialTask?.task.cancel() }
}

@MainActor final class RemoteTerminalSubscription {
    private let feed: RemoteTerminalFeed
    private let id: UUID
    let initial: RemoteTerminalFrame
    fileprivate init(feed: RemoteTerminalFeed, id: UUID, initial: RemoteTerminalFrame) { self.feed = feed; self.id = id; self.initial = initial }
    func next() async throws -> RemoteTerminalFrame { try await feed.next(id) }
    func cancel() { feed.remove(id) }
    deinit {
        let feed = feed, id = id
        Task { @MainActor in feed.remove(id) }
    }
}
