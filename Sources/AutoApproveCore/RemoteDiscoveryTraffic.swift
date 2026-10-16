import Foundation
import Network

/// One budget for discovery and metadata checks, independent of browser and input traffic.
actor RemoteDiscoveryTraffic {
    static let shared = RemoteDiscoveryTraffic()
    private var active = 0
    private var nextStart: TimeInterval = 0
    private var knownWaiters = 0
    private var lastBlindStart = -TimeInterval.infinity

    private func enter(known: Bool) async throws {
        if known { knownWaiters += 1 }
        defer { if known { knownWaiters -= 1 } }
        while true {
            try Task.checkCancellation()
            let now = ProcessInfo.processInfo.systemUptime
            // Saved identities take the next budgeted slot. Keep an occasional
            // blind probe possible during a long stale-peer recovery pass.
            let eligible = known || knownWaiters == 0 || now-lastBlindStart >= 2
            if active < 2, now >= nextStart, eligible {
                active += 1; nextStart = now + 0.25
                if !known { lastBlindStart = now }
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
    func get(_ endpoint: NWEndpoint, path: String, expectedID: String? = nil, timeout: TimeInterval = 1) async throws -> RemoteHTTPResponse {
        try await enter(known:expectedID != nil); defer { active -= 1 }
        // A later scheduled probe is preferable to hidden retries during discovery.
        return try await RemoteHTTPExchange(endpoint: endpoint, path: path, method: "GET", body: Data(), expectedNodeID: expectedID, timeout: timeout, retryReads: false).run()
    }
}

actor RemoteDashboardTraffic {
    static let shared = RemoteDashboardTraffic()
    private var active = 0
    func read(foreground: Bool = false, _ operation: @Sendable () async throws -> RemoteHTTPResponse) async throws -> RemoteHTTPResponse {
        // A bookmarked/selected Mac cannot queue behind three dead inventories.
        // The overall four-read budget remains unchanged.
        while active >= (foreground ? 4 : 3) { try Task.checkCancellation(); try await Task.sleep(for: .milliseconds(50)) }
        try Task.checkCancellation(); active += 1; defer { active -= 1 }
        return try await operation()
    }
}
