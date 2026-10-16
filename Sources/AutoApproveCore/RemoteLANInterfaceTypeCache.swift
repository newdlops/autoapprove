import Foundation

/// Only hardware classification is reusable. IPs, masks and flags must always
/// come from the current getifaddrs snapshot. The caller holds the LAN lock.
struct RemoteLANInterfaceTypeCache<Value> {
    private var values: [String: Value] = [:]
    private var names = Set<String>()
    private var until: TimeInterval = -.infinity

    mutating func resolve(names requested: Set<String>, refresh: Bool, at now: TimeInterval,
                          load: () -> [String: Value]) -> [String: Value] {
        guard !requested.isEmpty else { return [:] }
        if !refresh, now < until, requested.isSubset(of: names) { return values }
        values = load()
        // A missing classification can be a transient OS inventory failure.
        // Retry it at the next IP refresh rather than caching that absence.
        names = Set(values.keys)
        until = now + 30
        return values
    }
}
