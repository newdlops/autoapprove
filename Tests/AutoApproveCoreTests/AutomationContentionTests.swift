import Foundation
import AutoApproveCore

extension ApprovalTests {
    func testProfileSaveCompletesWhileTerminalIsOccupied() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let gate = AutomationIPC(), entered = DispatchSemaphore(value:0), release = DispatchSemaphore(value:0)
        let occupied = Task.detached {
            try gate.runInput(host:"Terminal",budget:8) {
                entered.signal()
                return release.wait(timeout:.now()+7) == .success
            }
        }
        defer { release.signal() }
        while entered.wait(timeout:.now()) != .success { try await Task.sleep(for:.milliseconds(1)) }
        let records = ProcessDiscovery.parse("""
        991111 1 ttys930 991111 991111 Wed Oct 28 12:00:00 2026 /fixture/codex
        991112 1 ttys931 991112 991112 Wed Oct 28 12:00:00 2026 /fixture/codex
        """)
        let thread = UUID().uuidString.lowercased(), other = UUID().uuidString.lowercased()
        let transport = CodexReplyTransport(prepare:{_,_ in throw AppError.message("Unexpected input")},send:{_,_ in throw AppError.message("Unexpected input")},
            queueHome:{_ in .init(executable:"",home:root.path,threadID:"")})
        let queue = CodexQueueTransport(list:{_ in []},delete:{_,_ in .init(removed:[])},
            conversations:{_,_ in [.init(id:other,title:"Other",name:"Other")]})
        let adapter = ScreenHostAdapter(screens:{_ in .init()},approve:{_,_,_ in .missingTarget},reveal:{_ in nil})
        let engine = try ApprovalEngine(paths:.init(directory:root),questionTransport:transport,processReader:{records},screenAdapters:[.terminal:adapter],codexQueue:queue,
            codexGroupReader:{ record in record.pid == records[0].pid ? .init(threadID:thread,database:root.appendingPathComponent("state_5.sqlite").path) : nil },
            profileExecutionSettingsReader:{ _ in .init(model:"model",reasoningEffort:"high") },isolateByDefault:true,terminalProfileLayoutReader:{ _ in
                try gate.run(host:"Terminal",readOnly:true,budget:1) { throw AppError.message("Unexpected layout read") }
            })
        defer { engine.stop() }
        let sessions = records.map { record in
            var session = AgentSession(id:record.key,agent:.codex,pid:record.pid,started:record.started,tty:"/dev/"+record.tty,cwd:root.path,terminal:.terminal)
            session.terminalTitle="Other | "+root.lastPathComponent
            return session
        }
        engine.updateDiscovery(sessions,records:records)
        do {
            _ = try await engine.terminalProfileSaveCandidates(readWindowLayout:true)
            throw AppError.message("Expected live layout to require the occupied host")
        } catch AutomationIPC.Failure.busy {}
        let candidates = try await engine.terminalProfileSaveCandidates(readWindowLayout:false)
        guard let unknown = candidates.first(where: { $0.id == records[1].key }) else { throw AppError.message("Missing unresolved session") }
        try expectEqual(unknown.conversations.map(\.id),[other])
        try expectEqual(unknown.entry.conversationID,"")
        let selected = try await engine.terminalProfileSaveCandidates(readWindowLayout:false,sessionIDs:[records[0].key])
        let store = TerminalProfileStore(directory:root.appendingPathComponent("profiles"))
        let saved = try store.save(.init(name:"Concurrent",entries:selected.map(\.entry)))
        let persisted = try TerminalProfileStore.decode(TerminalProfileStore.read(store.file(saved.id)))
        try expectEqual(persisted.entries.map(\.conversationID),[thread])
        try expectEqual(persisted.entries.first?.executionSettings?.reasoningEffort,"high")
        try expectNil(persisted.entries.first?.terminalTab)
        try expectEqual(gate.snapshot().inFlight,1)
        release.signal()
        try expect(try await occupied.value)
    }

    @MainActor func testWindowRefreshPreservesHostInput() async throws {
        let started = DispatchSemaphore(value: 0), finish = DispatchSemaphore(value: 0)
        defer { finish.signal() }
        let host = ScreenHost.terminal
        let pending = Task.detached {
            try AutomationIPC.shared.runInput(host: host.title, budget: 3) {
                started.signal()
                return finish.wait(timeout: .now() + 2) == .success
            }
        }
        let entered = await Task.detached { started.wait(timeout: .now() + 1) == .success }.value
        try expect(entered)
        let capture = TerminalWindowCapture(host: host, requestPermissions: {})
        capture.requestPermissions()
        capture.invalidate()
        finish.signal()
        try expect(try await pending.value)
    }

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
