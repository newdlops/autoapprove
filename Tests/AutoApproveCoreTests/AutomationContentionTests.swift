import Foundation
import AutoApproveCore

extension ApprovalTests {
    func testBlockedAutomationIsolation() async throws {
        let gate = AutomationIPC(cooldown:0.04)
        let release = DispatchSemaphore(value:0), entered = DispatchSemaphore(value:0)
        defer { release.signal() }
        let slow = Task.detached {
            try gate.run(host:"Terminal",readOnly:true,budget:0.1) {
                entered.signal()
                release.wait()
                return 17
            }
        }
        while entered.wait(timeout:.now()) != .success { try await Task.sleep(for:.milliseconds(2)) }
        let other = try await Task.detached { try gate.run(host:"iTerm2",readOnly:true,budget:0.2) { 42 } }.value
        try expectEqual(other,42)
        do { _ = try await slow.value; throw AppError.message("Late result accepted") } catch is AutomationIPC.Failure {}
        for _ in 0..<20 {
            try expectThrows(try gate.run(host:"Terminal",readOnly:true,budget:0.05) { 0 })
        }
        try expectEqual(gate.snapshot().inFlight,1)
        release.signal()
        while gate.snapshot().inFlight != 0 { try await Task.sleep(for:.milliseconds(5)) }
        try expectThrows(try gate.run(host:"Terminal",readOnly:false,budget:0.2) { 0 })
        try await Task.sleep(for:.milliseconds(50))
        let result = try await Task.detached { try gate.run(host:"Terminal",readOnly:true,budget:0.2) { 23 } }.value
        try expectEqual(result,23)
        try expectEqual(gate.snapshot().late,1)
    }
}

extension ApprovalTests {
    func testPermissionAndCancelledFlights() async throws {
        let gate = AutomationIPC(cooldown:0.05)
        let entered = DispatchSemaphore(value:0), release = DispatchSemaphore(value:0)
        defer { release.signal() }
        let first = Task.detached { try gate.permission(host:"A",key:"process-1/get",cacheOnly:false) {
            entered.signal(); release.wait(); return 0
        } }
        while entered.wait(timeout:.now()) != .success { try await Task.sleep(for:.milliseconds(2)) }
        for _ in 0..<20 {
            let joined = try gate.permission(host:"A",key:"process-1/get",cacheOnly:true) { fatalError("Duplicate permission IPC") }
            try expect(joined == nil)
        }
        release.signal()
        try expectEqual(try await first.value,0)
        try expectEqual(try gate.permission(host:"A",key:"process-1/get",cacheOnly:true) { fatalError("Missed TTL") },0)
        try expectEqual(try gate.permission(host:"A",key:"process-2/get",cacheOnly:false) { -1743 },-1743)
        gate.invalidate("A")
        let blocked = Task { try await gate.read(host:"A") { entered.signal(); release.wait(); return true } }
        while entered.wait(timeout:.now()) != .success { try await Task.sleep(for:.milliseconds(2)) }
        blocked.cancel()
        do { _ = try await blocked.value; throw AppError.message("Cancelled read succeeded") } catch is CancellationError {}
        try expectEqual(gate.snapshot().inFlight,1)
        let other = Task { try await gate.read(host:"B") { entered.signal(); release.wait(); return true } }
        while entered.wait(timeout:.now()) != .success { try await Task.sleep(for:.milliseconds(2)) }
        try expectThrows(try gate.run(host:"C",readOnly:true,budget:0.05) { 0 })
        release.signal(); release.signal()
        try expect(try await other.value)
    }

    func testStaleKeyboardSampleRetainsPriority() async throws {
        final class Clock: @unchecked Sendable {
            let lock = NSLock()
            var time = 100.0
            func now() -> Double { lock.withLock { time } }
            func advance() { lock.withLock { time += 0.2 } }
        }
        let clock = Clock(), first = DispatchSemaphore(value:0), block = DispatchSemaphore(value:0)
        defer { block.signal() }
        let provider = KeyboardActivitySampler(clock:clock.now) {
            if first.wait(timeout:.now()) != .success { block.wait() }
            return .init(idle:8,flags:[],bundle:"com.apple.Terminal")
        }
        first.signal()
        try expect(provider.sample() == nil)
        for _ in 0..<30 {
            if provider.sample() != nil { break }
            try await Task.sleep(for:.milliseconds(5))
        }
        try expect(provider.sample() != nil)
        clock.advance()
        try expect(provider.sample() == nil)
        try await Task.sleep(for:.milliseconds(50))
        try expect(provider.sample() == nil)
        clock.lock.withLock { clock.time += 10 }
    }
}
