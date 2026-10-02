// Real DNS-SD registration with a unique QA hostname; no user sessions or settings.
import Foundation
import Darwin
import dnssd
@testable import AutoApproveCore

@main struct NamedAccessCheck {
    @MainActor static func main() async throws {
        let host = "autoapprove-qa-" + UUID().uuidString.prefix(8).lowercased() + ".local"
        let first = RemoteNamedAccess(nodeID: UUID().uuidString, portalHost: host, onChange: {})
        let second = RemoteNamedAccess(nodeID: UUID().uuidString, portalHost: host, onChange: {})
        defer { first.stop(); second.stop() }
        func wait(_ condition: @MainActor () -> Bool) async throws {
            for _ in 0..<150 {
                if condition() { return }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw AppError.message("DNS registration did not settle")
        }
        func check(_ value: Bool, _ message: String) throws { if !value { throw AppError.message(message) } }
        func resolve(_ hostname: String) async throws {
            var lastError: Int32 = 0
            for _ in 0..<10 {
                lastError = await Task.detached {
                    var result: UnsafeMutablePointer<addrinfo>?
                    let error = getaddrinfo(hostname, nil, nil, &result)
                    if let result { freeaddrinfo(result) }
                    return error
                }.value
                if lastError == 0 { return }
                try await Task.sleep(for: .milliseconds(500))
            }
            throw AppError.message("Named host did not resolve: \(hostname) (\(lastError))")
        }
        // CNAME data is wire encoded, so invalid DNS labels never reach the API.
        try check(RemoteDNSAlias.cnameRecord("a.local.") == Data([1, 97, 5, 108, 111, 99, 97, 108, 0]), "CNAME wire format")
        try check(RemoteDNSAlias.cnameRecord("a..local") == nil, "Empty DNS label accepted")
        try check(RemoteDNSAlias.cnameRecord(String(repeating: "a", count: 64) + ".local") == nil, "Long DNS label accepted")
        first.update(port: 8765, anotherPortal: false)
        try await wait { first.ownsPortal && first.personalReady }
        try check(first.urls(port: 8765, anotherPortal: false).first == "http://\(host):8765", "Shared address must be primary")
        try await resolve(host)
        print("PASS: initial shared name resolution"); fflush(stdout)
        second.update(port: 8765, anotherPortal: true)
        try await wait { second.personalReady }
        try check(!second.ownsPortal && second.urls(port: 8765, anotherPortal: true).first == "http://\(host):8765", "Standby must use discovered owner")
        first.stop()
        try check(!first.ownsPortal && !first.personalReady, "OFF did not release registrations")
        second.update(port: 8765, anotherPortal: false)
        try await wait { second.ownsPortal }
        try await resolve(host)
        print("PASS: name resolution after handoff"); fflush(stdout)
        second.stop()
        second.update(port: 45678, anotherPortal: false)
        try await wait { second.personalReady }
        try check(!second.ownsPortal && second.urls(port: 45678, anotherPortal: false).first?.hasSuffix(":45678") == true, "Nonstandard port must use its own named address")
        second.stop()
        // A conflicting CNAME remains untouched and does not become our portal.
        let conflictHost = "autoapprove-conflict-" + UUID().uuidString.prefix(8).lowercased() + ".local"
        let foreign = RemoteDNSAlias(hostname: conflictHost, onChange: {})
        let competing = RemoteNamedAccess(nodeID: UUID().uuidString, portalHost: conflictHost, onChange: {})
        defer { foreign.configure(target: nil); competing.stop() }
        foreign.configure(target: "foreign-qa-host.local.")
        try await wait { foreign.ready }
        competing.update(port: 8765, anotherPortal: false)
        try await wait { competing.personalReady }
        try await Task.sleep(for: .seconds(2))
        try check(!competing.ownsPortal && competing.urls(port: 8765, anotherPortal: false).first?.contains(competing.personalHost!) == true, "Foreign name conflict must retain personal fallback")
        print("PASS: real named resolution, shared-address priority/standby/handoff, OFF/restart, nonstandard-port fallback, foreign-name conflict")
    }
}
