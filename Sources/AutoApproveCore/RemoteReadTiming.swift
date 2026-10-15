import Foundation

/// Application response times, including server work, rather than TCP RTTs.
/// The EWMA/variation estimator follows RFC 6298's update order and weights;
/// its 75–750ms bounds govern an optional second GET, not TCP retransmission.
public struct RemoteReadTiming: Sendable {
    public enum Kind: Hashable, Sendable {
        case inventory, terminal, other, stream
        public static func finite(path: String) -> Self {
            switch path.split(separator: "?", maxSplits: 1).first {
            case "/api/state", "/api/inventory": return .inventory
            case "/api/terminal", "/api/pty/output": return .terminal
            default: return .other
            }
        }
    }
    private struct Key: Hashable, Sendable { let route: String; let kind: Kind }
    private struct Sample: Sendable { var mean: TimeInterval; var variation: TimeInterval; var at: TimeInterval }
    private var samples: [Key: Sample] = [:]
    public var count: Int { samples.count }
    public init() {}

    public func delay(route: String, kind: Kind, at now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> TimeInterval {
        guard now.isFinite, let sample = samples[Key(route: route, kind: kind)],
              now >= sample.at, now - sample.at < 120 else { return 0.2 }
        return min(0.75, max(0.075, sample.mean + max(0.025, 4 * sample.variation)))
    }

    /// Call only for the winning, validated response of a GET. Failed, cancelled
    /// and losing requests never teach the estimator; no terminal data is kept.
    public mutating func observe(route: String, kind: Kind, elapsed: TimeInterval,
                                 at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard !route.isEmpty, route.utf8.count <= 512, elapsed.isFinite, (0...30).contains(elapsed),
              now.isFinite, now >= 0 else { return }
        samples = samples.filter { now >= $0.value.at && now - $0.value.at < 120 }
        let key = Key(route: route, kind: kind), value = max(0.001, elapsed)
        if var sample = samples[key] {
            sample.variation = 0.75 * sample.variation + 0.25 * abs(sample.mean - value)
            sample.mean = 0.875 * sample.mean + 0.125 * value
            sample.at = now; samples[key] = sample
        } else {
            if samples.count >= 16, let oldest = samples.min(by: { $0.value.at < $1.value.at })?.key { samples.removeValue(forKey: oldest) }
            samples[key] = Sample(mean: value, variation: value / 2, at: now)
        }
    }
}
