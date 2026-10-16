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
    }
    private struct Samples {
        var count: UInt64 = 0, failures: UInt64 = 0
        var values: [Double] = []
        var next = 0
    }
    private let lock = NSLock()
    private var stages: [Stage:Samples] = [:]
    private var counters: [Counter:UInt64] = [:]
    public static let sampleLimit = 256
    public init() {}
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
        lock.lock(); let values = stages, counts = counters; lock.unlock()
        let summaries = Dictionary(uniqueKeysWithValues:values.map { stage, samples in
            let sorted = samples.values.sorted()
            func percentile(_ p: Double) -> Double { sorted[max(0,Int(ceil(Double(sorted.count)*p))-1)] }
            return (stage.rawValue,Summary(count:samples.count,failures:samples.failures,sampleCount:sorted.count,
                medianMS:percentile(0.5),p95MS:percentile(0.95),maximumMS:sorted.last ?? 0))
        })
        return Snapshot(sampleLimit:Self.sampleLimit,stages:summaries,counters:Dictionary(uniqueKeysWithValues:counts.map{($0.key.rawValue,$0.value)}))
    }
}
