#if DEBUG
import Foundation
@testable import AutoApproveCore

extension ApprovalTests {
    func testNativeTerminalInputHoldRejectsWrongIdentityAndEarlyRelease() throws {
        let nonce = String(repeating: "a", count: 32)
        let generation = "00000000-0000-4000-8000-000000000001"
        let lease = "00000000-0000-4000-8000-000000000002"
        let peer = CodexNativePeerIdentity(source: "macos-audit-token", pid: 123, effectiveUid: 501,
            effectiveGid: 20, auditPidVersion: 7)
        func reply(held: Bool, leaseID: String?) -> [String: Any] {
            ["schemaVersion": 1, "producer": "autoapprove-native-tui-input-hold", "pid": peer.pid,
             "nonce": nonce, "generation": generation, "leaseId": leaseID as Any? ?? NSNull(),
             "leaseActive": held, "terminalInputBlocked": held, "leaseTTLMillis": held ? 29_000 : 0,
             "acceptedWorkStopped": false, "membershipComplete": false, "migrationAuthorized": false]
        }
        func check(_ value: [String: Any], _ operation: CodexNativeTerminalInputHold.Operation) throws {
            _ = try CodexNativeTerminalInputHold.validate(JSONSerialization.data(withJSONObject: value),
                operation: operation, nonce: nonce, peer: peer,
                generation: operation == .inspect ? nil : generation,
                leaseID: operation == .inspect || operation == .pause ? nil : lease)
        }
        try check(reply(held: false, leaseID: nil), .inspect)
        for operation in [CodexNativeTerminalInputHold.Operation.pause, .status, .renew] {
            try check(reply(held: true, leaseID: lease), operation)
        }
        try check(reply(held: false, leaseID: lease), .release)
        let invalid: [(String, Any)] = [
            ("pid", 999), ("schemaVersion", 2), ("producer", "other"), ("nonce", String(repeating: "b", count: 32)),
            ("generation", "00000000-0000-4000-8000-000000000009"),
            ("leaseId", "00000000-0000-4000-8000-000000000009"),
            ("leaseActive", false), ("terminalInputBlocked", false), ("leaseTTLMillis", 30_001),
            ("acceptedWorkStopped", true), ("membershipComplete", true), ("migrationAuthorized", true),
            ("terminalInputBlocked", 1), ("leaseTTLMillis", true)
        ]
        for (field, value) in invalid {
            var bad = reply(held: true, leaseID: lease); bad[field] = value
            try expectThrows(check(bad, .status))
        }
        var early = reply(held: false, leaseID: lease)
        early["terminalInputBlocked"] = true
        try expectThrows(check(early, .release))
        try expectThrows(check(reply(held: true, leaseID: lease), .release))
    }
}
#endif
