import Foundation
import AutoApproveCore

extension ApprovalTests {
    func testReadTimingLearnsLoadAndVariationWithinRecoveryBounds() throws {
        var timing = RemoteReadTiming()
        try expectEqual(timing.delay(route: "lan", kind: .terminal, at: 1), 0.2)
        for step in 1...12 { timing.observe(route: "lan", kind: .terminal, elapsed: 0.28, at: Double(step)) }
        let busy = timing.delay(route: "lan", kind: .terminal, at: 13)
        try expect(busy > 0.28 && busy <= 0.75, "A healthy busy route needs time to answer before duplicating work")
        timing.observe(route: "lan", kind: .terminal, elapsed: 0.6, at: 14)
        try expect(timing.delay(route: "lan", kind: .terminal, at: 14) > busy, "Jitter increases the recovery allowance")
        for step in 15...80 { timing.observe(route: "lan", kind: .terminal, elapsed: 0.01, at: Double(step)) }
        try expectEqual(timing.delay(route: "lan", kind: .terminal, at: 80), 0.075, "A learned fast path wakes the alternate sooner")
        timing.observe(route: "very-busy", kind: .stream, elapsed: 30, at: 81)
        try expectEqual(timing.delay(route: "very-busy", kind: .stream, at: 82), 0.75, "A pathological sample cannot postpone recovery indefinitely")
    }

    func testReadTimingIsolatesRoutesOperationsAndExpiredKnowledge() throws {
        var timing = RemoteReadTiming()
        timing.observe(route: "wifi:8765", kind: .terminal, elapsed: 0.28, at: 10)
        try expectEqual(timing.delay(route: "ethernet:8765", kind: .terminal, at: 11), 0.2)
        try expectEqual(timing.delay(route: "wifi:8766", kind: .terminal, at: 11), 0.2)
        try expectEqual(timing.delay(route: "wifi:8765", kind: .stream, at: 11), 0.2)
        try expectEqual(timing.delay(route: "wifi:8765", kind: .inventory, at: 11), 0.2)
        try expectEqual(timing.delay(route: "wifi:8765", kind: .terminal, at: 130), 0.2)
        try expectEqual(timing.delay(route: "wifi:8765", kind: .terminal, at: 9), 0.2)
        var otherPeer = RemoteReadTiming()
        otherPeer.observe(route: "wifi:8765", kind: .terminal, elapsed: 0.01, at: 11)
        try expect(timing.delay(route: "wifi:8765", kind: .terminal, at: 11) > otherPeer.delay(route: "wifi:8765", kind: .terminal, at: 11))
        try expectEqual(RemoteReadTiming.Kind.finite(path: "/api/terminal?session=one"), .terminal)
        try expectEqual(RemoteReadTiming.Kind.finite(path: "/api/inventory"), .inventory)
        try expectEqual(RemoteReadTiming.Kind.finite(path: "/api/update/manifest"), .other)
    }

    func testReadTimingRejectsInvalidSamplesAndBoundsStorage() throws {
        var timing = RemoteReadTiming()
        for value in [-1, Double.nan, Double.infinity, 30.001] {
            timing.observe(route: "invalid", kind: .stream, elapsed: value, at: 1)
        }
        timing.observe(route: "", kind: .stream, elapsed: 0.1, at: 1)
        timing.observe(route: String(repeating: "x", count: 513), kind: .stream, elapsed: 0.1, at: 1)
        timing.observe(route: "invalid-time", kind: .stream, elapsed: 0.1, at: .nan)
        try expectEqual(timing.count, 0)
        for step in 0..<40 { timing.observe(route: "route-\(step)", kind: .stream, elapsed: 0.01, at: Double(step)) }
        try expectEqual(timing.count, 16)
        try expectEqual(timing.delay(route: "route-0", kind: .stream, at: 40), 0.2)
        try expectEqual(timing.delay(route: "route-39", kind: .stream, at: 40), 0.075)
        timing.observe(route: "new-network", kind: .stream, elapsed: 0.01, at: 160)
        try expectEqual(timing.count, 1, "New observations discard old network knowledge")
    }
}
