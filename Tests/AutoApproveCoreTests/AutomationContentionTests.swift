import Foundation
import AutoApproveCore

extension ApprovalTests {
    func testInteractiveReadAndInputAdmissionRecover() async throws {
        let gate = AutomationIPC(cooldown:0.02)
        let entered = DispatchSemaphore(value:0), release = DispatchSemaphore(value:0)
        defer { release.signal() }
        let monitor = Task { try await gate.read(host:"Terminal") { entered.signal(); release.wait(); return 1 } }
        while entered.wait(timeout:.now()) != .success { try await Task.sleep(for:.milliseconds(1)) }
        let validation = Task { try await gate.read(host:"Terminal",waitForSlot:true) { 2 } }
        do {
            _ = try gate.runInput(host:"Terminal",budget:1) { fatalError("Input ran while occupied") }
            throw AppError.message("Expected an admission refusal")
        } catch is AutomationIPC.InputNotStarted {}
        try await Task.sleep(for:.milliseconds(50))
        release.signal()
        try expectEqual(try await monitor.value,1)
        try expectEqual(try await validation.value,2)
        let sent = try gate.runInput(host:"Terminal",budget:1) {
            try gate.run(host:"Terminal",readOnly:false,budget:0.2) { 3 }
        }
        try expectEqual(sent,3)
        do {
            _ = try gate.runInput(host:"Terminal",budget:1) { throw AutomationIPC.Failure.busy }
            throw AppError.message("Expected transport failure")
        } catch AutomationIPC.Failure.busy {}
    }

    @MainActor func testMonitorRecoversVerifiedConnectionAfterTimeout() async throws {
        final class Probe: @unchecked Sendable {
            let lock = NSLock()
            var calls = 0
            func read(_ targets: [ScreenTarget]) throws -> TerminalSnapshot {
                let count = lock.withLock { calls += 1; return calls }
                if count == 2 { throw AutomationIPC.Failure.timeout }
                return TerminalSnapshot(screens:targets.map { TerminalScreen(tty:$0.tty, contents:"Working\nesc to interrupt") })
            }
        }
        let probe = Probe(), root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let adapter = ScreenHostAdapter(screens:{ try probe.read($0) }, approve:{ _,_,_ in .missingTarget }, reveal:{ _ in nil })
        let engine = try ApprovalEngine(paths:AppPaths(directory:root), screenAdapters:[.terminal:adapter], nativeKeyboardActivity:.inactive)
        defer { engine.stop() }
        let session = AgentSession(id:"fixture",agent:.codex,pid:42,started:"fixture",tty:"/dev/ttys621",cwd:root.path,terminal:.terminal)
        engine.updateDiscovery([session],records:[])
        await engine.connectScreenHost(.terminal)
        await engine.refreshScreenHost(.terminal)
        try expect(engine.snapshot.health.terminalConnected && engine.snapshot.health.terminal.contains("재확인"))
        try expectEqual(engine.snapshot.sessions.first?.channel, .terminalScreen)
        try await Task.sleep(for:.milliseconds(1100))
        await engine.refreshScreenHost(.terminal)
        try expect(engine.snapshot.health.terminalConnected && engine.snapshot.health.terminal.contains("연결됨"))
        try expectEqual(probe.lock.withLock { probe.calls },3)
    }

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
