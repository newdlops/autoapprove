import Foundation

/// Local, bounded duration samples. Never accepts source IDs, paths, contents,
/// requests or addresses. Snapshot/percentile work runs only on explicit reads.
public final class RemoteTerminalPerformance: @unchecked Sendable {
    public static let shared = RemoteTerminalPerformance()
    public enum Stage: String, CaseIterable, Codable, Sendable {
        case mainQueue, automation, automationQuery, identity, textRead, presentationRead
        case terminalContents, terminalMetadata
        case firstFrame, liveFrame, responseEncoding, transferPreparation, initialWrite
        case relayHTTP, relayStreamOpen
    }
    public enum Counter: String, CaseIterable, Codable, Sendable {
        case initialReads, sharedInitialReads, abandonedInitialReads
        case liveProducers, liveReads, sharedSubscribers, resumeHits, resumeMisses, compactPulses
        case nativeObservers, sharedNativeObservers, releasedNativeObservers
    }
    public struct Summary: Codable, Sendable {
        public var count: UInt64
        public var failures: UInt64
        public var sampleCount: Int
        public var medianMS: Double
        public var p95MS: Double
        public var maximumMS: Double
    }
    public struct Snapshot: Codable, Sendable {
        public var sampleLimit: Int
        public var stages: [String:Summary]
        public var counters: [String:UInt64]
        public var nativeReads: NativeReads?
    }
    public enum NativePurpose: String, Codable, Sendable { case monitor, validation, firstFrame, liveFrame, other }
    public enum NativeQuery: String, Codable, Sendable {
        case text, bulkContentsBefore, bulkContents, bulkContentsAfter, bulkBefore, bulkTitle, bulkAfter, customTitle
        case selectedWindow, selectedConfirm, windowBefore, windowSelection, windowName, windowAfter, other
    }
    public enum NativeFailure: String, Codable, Sendable { case permission, timeout, cancelled, other }
    public struct NativeReply: Codable, Sendable {
        public var kind: UInt32
        public var items: Int
        public init(kind: UInt32 = 0, items: Int = 0) { self.kind = kind; self.items = items }
    }
    public struct NativeEvent: Codable, Sendable {
        public var purpose: NativePurpose
        public var query: NativeQuery
        public var targets: Int
        public var started: TimeInterval
        public var durationMS: Double
        public var remainingMS: Double
        public var inFlightAtStart: Int
        public var overlapped: Bool
        public var failure: NativeFailure?
        public var code: Int?
        public var reply: NativeReply?
    }
    public struct NativeReads: Codable, Sendable {
        public var eventLimit: Int
        public var thresholdMS: Double
        public var active: Int
        public var maximumActive: Int
        public var events: [NativeEvent]
    }
    private struct Samples {
        var count: UInt64 = 0, failures: UInt64 = 0
        var values: [Double] = []
        var next = 0
    }
    private let lock = NSLock()
    private var stages: [Stage:Samples] = [:]
    private var counters: [Counter:UInt64] = [:]
    private struct NativeTicket {
        var started: TimeInterval
        var active: Int
        var overlap: UInt64
    }
    private var nativeActive = 0, nativeMaximumActive = 0, nativeNext = 0
    private var nativeOverlap: UInt64 = 0
    private var nativeEvents: [NativeEvent] = []
    private static let nativeEventLimit = 32
    private static let nativeThreshold: TimeInterval = 0.25
    public static let sampleLimit = 256
    private let nativeClock: @Sendable () -> TimeInterval
    public init(clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) { nativeClock = clock }
    public func measureNativeQuery<T>(purpose: NativePurpose, query: NativeQuery, targets: Int, remaining: TimeInterval,
                                      reply: (T) -> NativeReply = { _ in NativeReply() }, _ operation: () throws -> T) rethrows -> T {
        let started = nativeClock()
        let ticket = lock.withLock { () -> NativeTicket in
            if nativeActive > 0 { nativeOverlap &+= 1 }
            nativeActive += 1; nativeMaximumActive = max(nativeMaximumActive,nativeActive)
            return NativeTicket(started:started,active:nativeActive,overlap:nativeOverlap)
        }
        do {
            let value = try operation(), ended = nativeClock()
            // Fast successes retain no event or reply descriptor. Inspect only
            // the numeric shape of a slow reply, never its data or string value.
            let shape = ended-ticket.started >= Self.nativeThreshold ? reply(value) : nil
            finishNative(ticket,purpose:purpose,query:query,targets:targets,remaining:remaining,ended:ended,reply:shape,error:nil)
            return value
        } catch {
            finishNative(ticket,purpose:purpose,query:query,targets:targets,remaining:remaining,ended:nativeClock(),reply:nil,error:error)
            throw error
        }
    }
    private func finishNative(_ ticket: NativeTicket, purpose: NativePurpose, query: NativeQuery, targets: Int,
                              remaining: TimeInterval, ended: TimeInterval, reply: NativeReply?, error: Error?) {
        let elapsed = ended-ticket.started
        lock.lock(); defer { lock.unlock() }
        nativeActive -= 1
        guard elapsed.isFinite, elapsed >= 0, (elapsed*1000).isFinite,
              elapsed >= Self.nativeThreshold || error != nil else { return }
        let code = error.map { ($0 as NSError).code }
        let failure: NativeFailure?
        if error is CancellationError { failure = .cancelled }
        else if error is TerminalAdapterError || code == -1743 || code == -1744 { failure = .permission }
        else if code == -1712 { failure = .timeout }
        else { failure = error == nil ? nil : .other }
        let remainingMS = remaining >= 0 && (remaining*1000).isFinite ? remaining*1000 : 0
        let event = NativeEvent(purpose:purpose,query:query,targets:max(0,targets),started:ticket.started,
            durationMS:elapsed*1000,remainingMS:remainingMS,inFlightAtStart:ticket.active,
            overlapped:ticket.active > 1 || ticket.overlap != nativeOverlap,failure:failure,code:code,reply:reply)
        if nativeEvents.count < Self.nativeEventLimit { nativeEvents.append(event) }
        else { nativeEvents[nativeNext] = event }
        nativeNext = (nativeNext+1)%Self.nativeEventLimit
    }
    public static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    public func observe(_ stage: Stage, elapsed: TimeInterval, succeeded: Bool = true) {
        guard elapsed.isFinite, elapsed >= 0, (elapsed*1000).isFinite else { return }
        lock.lock(); defer { lock.unlock() }
        Self.append(&stages[stage,default:Samples()],milliseconds:elapsed*1000,succeeded:succeeded)
    }
    private static func append(_ samples: inout Samples, milliseconds: Double, succeeded: Bool) {
        samples.count = samples.count == .max ? .max : samples.count+1
        if !succeeded { samples.failures = samples.failures == .max ? .max : samples.failures+1 }
        if samples.values.count < Self.sampleLimit { samples.values.append(milliseconds) }
        else { samples.values[samples.next] = milliseconds }
        samples.next = (samples.next+1)%Self.sampleLimit
    }
    public func increment(_ counter: Counter) {
        lock.lock(); defer { lock.unlock() }
        let count = counters[counter,default:0]; counters[counter] = count == .max ? .max : count+1
    }
    public func measure<T>(_ stage: Stage, _ operation: () throws -> T) rethrows -> T {
        let start = Self.now; var succeeded = false
        defer { observe(stage,elapsed:Self.now-start,succeeded:succeeded) }
        let result = try operation(); succeeded = true; return result
    }
    public func snapshot() -> Snapshot {
        lock.lock()
        let values = stages, counts = counters
        let events = nativeEvents.count < Self.nativeEventLimit || nativeNext == 0 ? nativeEvents
            : Array(nativeEvents[nativeNext...])+Array(nativeEvents[..<nativeNext])
        let native = NativeReads(eventLimit:Self.nativeEventLimit,thresholdMS:Self.nativeThreshold*1000,
            active:nativeActive,maximumActive:nativeMaximumActive,events:events)
        lock.unlock()
        let summaries = Dictionary(uniqueKeysWithValues:values.map { stage, samples in
            let sorted = samples.values.sorted()
            func percentile(_ p: Double) -> Double { sorted[max(0,Int(ceil(Double(sorted.count)*p))-1)] }
            return (stage.rawValue,Summary(count:samples.count,failures:samples.failures,sampleCount:sorted.count,
                medianMS:percentile(0.5),p95MS:percentile(0.95),maximumMS:sorted.last ?? 0))
        })
        return Snapshot(sampleLimit:Self.sampleLimit,stages:summaries,counters:Dictionary(uniqueKeysWithValues:counts.map{($0.key.rawValue,$0.value)}),
            nativeReads:native)
    }
}
