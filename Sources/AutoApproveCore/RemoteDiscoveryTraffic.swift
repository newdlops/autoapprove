import Foundation
import Network

/// One budget for discovery and metadata checks, independent of browser and input traffic.
actor RemoteDiscoveryTraffic {
    static let shared = RemoteDiscoveryTraffic()
    private var active = 0
    private var nextStart: TimeInterval = 0

    private func enter() async throws {
        while true {
            try Task.checkCancellation()
            let now = ProcessInfo.processInfo.systemUptime
            if active < 2, now >= nextStart {
                active += 1; nextStart = now + 0.25; return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
    func get(_ endpoint: NWEndpoint, path: String, expectedID: String? = nil, timeout: TimeInterval = 1) async throws -> RemoteHTTPResponse {
        try await enter(); defer { active -= 1 }
        // A later scheduled probe is preferable to hidden retries during discovery.
        return try await RemoteHTTPExchange(endpoint: endpoint, path: path, method: "GET", body: Data(), expectedNodeID: expectedID, timeout: timeout, retryReads: false).run()
    }
}

actor RemoteDashboardTraffic {
    static let shared = RemoteDashboardTraffic()
    private var active = 0
    func read(_ operation: @Sendable () async throws -> RemoteHTTPResponse) async throws -> RemoteHTTPResponse {
        while active >= 4 { try Task.checkCancellation(); try await Task.sleep(for: .milliseconds(50)) }
        try Task.checkCancellation(); active += 1; defer { active -= 1 }
        return try await operation()
    }
}
