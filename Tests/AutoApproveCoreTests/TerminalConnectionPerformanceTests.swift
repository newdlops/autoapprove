import Foundation
import AutoApproveCore

private final class ConnectionReadGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var blocked = false, allowed = true, total = 0, completed = 0, mainThread = false, expired = false
    private var counts: [String:Int] = [:]
    func configure(blocked: Bool, allowed: Bool = true) {
        condition.lock(); self.blocked = blocked; self.allowed = allowed
        if !blocked { condition.broadcast() }; condition.unlock()
    }
    func read(_ key: String = "permission") -> Bool {
        condition.lock(); defer { completed += 1; condition.unlock() }
        total += 1; counts[key,default:0] += 1; mainThread = mainThread || Thread.isMainThread
        let answer = allowed, deadline = Date().addingTimeInterval(3)
        while blocked {
            if !condition.wait(until:deadline) { expired = true; break }
        }
        return answer
    }
    var count: Int { condition.lock(); defer { condition.unlock() }; return total }
    var finished: Int { condition.lock(); defer { condition.unlock() }; return completed }
    var queriedMainThread: Bool { condition.lock(); defer { condition.unlock() }; return mainThread }
    var timedOut: Bool { condition.lock(); defer { condition.unlock() }; return expired }
    func count(_ key: String) -> Int { condition.lock(); defer { condition.unlock() }; return counts[key,default:0] }
}

extension ApprovalTests {
    private func awaitConnectionCondition(_ predicate: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime+2
        while !predicate(), ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(for:.milliseconds(5)) }
        try expect(predicate(),"The connection operation must reach the expected state")
    }
    private func occupyConnectionActorUntilWorkerFinishes(_ predicate: () -> Bool) throws {
        let deadline = ProcessInfo.processInfo.systemUptime+1
        while !predicate(), ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval:0.001) }
        try expect(predicate()); Thread.sleep(forTimeInterval:0.02)
    }

    func testConnectionTimingSamplesAreBoundedAndContentFree() throws {
        let timing = RemoteTerminalPerformance()
        for index in 0..<1024 { timing.observe(.textRead,elapsed:Double(index)/1000,succeeded:index%4 != 0) }
        for value in [-1,Double.nan,Double.infinity,Double.greatestFiniteMagnitude] { timing.observe(.textRead,elapsed:value) }
        timing.increment(.initialReads); timing.increment(.sharedInitialReads)
        let snapshot = timing.snapshot(), sample = snapshot.stages["textRead"]!
        try expectEqual(sample.count,1024); try expectEqual(sample.failures,256)
        try expectEqual(sample.sampleCount,256); try expectEqual(snapshot.sampleLimit,256)
        try expect(abs(sample.medianMS-895) < 0.00001); try expect(abs(sample.p95MS-1011) < 0.00001)
        try expect(abs(sample.maximumMS-1023) < 0.00001)
        let data = try JSONEncoder().encode(snapshot), object = try JSONSerialization.jsonObject(with:data) as! [String:Any]
        try expectEqual(Set(object.keys),Set(["stages","counters","sampleLimit"]))
        let serialized = String(decoding:data,as:UTF8.self)
        for field in ["sessionID","tty","contents","address","pid","cwd"] { try expect(!serialized.contains(field)) }
        try expectEqual(snapshot.counters["sharedInitialReads"],1)
    }

    func testAutomationPreflightRunsOffMainAndDoesNotCacheGrants() async throws {
        let probe = ConnectionReadGate(); probe.configure(blocked:true)
        let capture = TerminalWindowCapture(automationQuery:{probe.read()})
        let first = Task { try await capture.checkAutomationPermission() }
        let second = Task { try await capture.checkAutomationPermission() }
        try await awaitConnectionCondition { probe.count == 1 }
        // This actor remains responsive while the synchronous system query waits.
        var heartbeat = false
        Task { @MainActor in heartbeat = true }
        try await awaitConnectionCondition { heartbeat }
        try expect(!probe.queriedMainThread); try expectEqual(probe.count,1)
        second.cancel(); probe.configure(blocked:false)
        let granted = try await first.value; try expect(granted)
        do { _ = try await second.value; throw AppError.message("Cancelled permission caller succeeded") }
        catch is CancellationError {}
        probe.configure(blocked:false,allowed:false)
        let denied = try await capture.checkAutomationPermission()
        try expect(!denied); try expectEqual(probe.count,2,"A completed grant must never be cached")
        probe.configure(blocked:true)
        let invalidated = Task { try await capture.checkAutomationPermission() }
        try await awaitConnectionCondition { probe.count == 3 }
        capture.invalidate(); probe.configure(blocked:false)
        do { _ = try await invalidated.value; throw AppError.message("Invalidated preflight succeeded") }
        catch is CancellationError {}
        _ = try await capture.checkAutomationPermission()
        try expectEqual(probe.count,4); try expect(!probe.timedOut)
    }

    func testCompletedPermissionQueryCannotAuthorizeALaterRequest() async throws {
        let probe = ConnectionReadGate(); probe.configure(blocked:true)
        let capture = TerminalWindowCapture(automationQuery:{probe.read()})
        let first = Task { try await capture.checkAutomationPermission() }
        try await awaitConnectionCondition { probe.count == 1 }
        probe.configure(blocked:false,allowed:false)
        // Intentionally keep this actor occupied after the worker has returned.
        // A new request must not join that completed grant while its old caller
        // is still waiting for an actor hop.
        try occupyConnectionActorUntilWorkerFinishes { probe.finished > 0 }
        let later = try await capture.checkAutomationPermission()
        let original = try await first.value
        try expect(original); try expect(!later,"A later request must observe the changed permission")
        try expectEqual(probe.count,2); try expect(!probe.timedOut)
    }

    func testInitialConnectionSharesOnlyConcurrentExactOriginals() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aa-initial-flight-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let records = ProcessDiscovery.parse("88 1 ttys080 88 88 Tue Sep 22 15:00:00 2026 /usr/local/bin/codex\n89 1 ttys081 89 89 Tue Sep 22 15:00:00 2026 /usr/local/bin/codex")
        var sessions = ProcessDiscovery.sessions(records)
        for index in sessions.indices { sessions[index].terminal = .terminal }
        let firstSession = sessions.first(where:{$0.pid == 88})!, otherSession = sessions.first(where:{$0.pid == 89})!
        let probe = ConnectionReadGate()
        let adapter = ScreenHostAdapter(screens:{targets in
            TerminalSnapshot(screens:targets.map { target in
                _ = probe.read(target.tty)
                return TerminalScreen(tty:target.tty,contents:"Fresh synthetic original "+target.tty)
            })
        },approve:{_,_,_ in .missingTarget},reveal:{_ in nil},presentationScreens:{targets in
            TerminalSnapshot(screens:targets.map { TerminalScreen(tty:$0.tty,contents:"Live cursor",cursor:TerminalCursor(offset:0)) })
        })
        let engine = try ApprovalEngine(paths:AppPaths(directory:directory),processReader:{records},screenAdapters:[.terminal:adapter],terminalInputAvailable:{false})
        defer { probe.configure(blocked:false); engine.stop() }
        engine.updateDiscovery(sessions,records:records); await engine.connectTerminal()
        try await Task.sleep(for:.milliseconds(2100))
        let before = probe.count, stats = RemoteTerminalPerformance.shared.snapshot().counters
        probe.configure(blocked:true)
        let readers = (0..<8).map { index in Task { try await engine.remoteTerminal(sessionID:firstSession.id,realtime:index%2 == 0,initial:true) } }
        let other = Task { try await engine.remoteTerminal(sessionID:otherSession.id,initial:true) }
        try await awaitConnectionCondition {
            let now = RemoteTerminalPerformance.shared.snapshot().counters
            return now["sharedInitialReads",default:0]-stats["sharedInitialReads",default:0] == 7 && probe.count == before+2
        }
        readers[0].cancel(); probe.configure(blocked:false)
        do { _ = try await readers[0].value; throw AppError.message("Cancelled first reader succeeded") }
        catch is CancellationError {}
        for reader in readers.dropFirst() {
            let frame = try await reader.value
            try expectEqual(frame.screen,"Fresh synthetic original "+firstSession.tty)
        }
        let otherFrame = try await other.value
        try expectEqual(otherFrame.screen,"Fresh synthetic original "+otherSession.tty)
        try expectEqual(probe.count,before+2,"Eight first readers plus another source must make exactly two source reads")
        let live = try await engine.remoteTerminal(sessionID:firstSession.id,realtime:true)
        try expectEqual(live.screen,"Live cursor"); try expect(live.cursor != nil)
        _ = try await engine.remoteTerminal(sessionID:firstSession.id,initial:true)
        try expectEqual(probe.count,before+3,"The next first request must perform a fresh read")
        let actual = RemoteTerminalPerformance.shared.snapshot().counters
        try expectEqual(actual["initialReads",default:0]-stats["initialReads",default:0],3)
        try expectEqual(actual["sharedInitialReads",default:0]-stats["sharedInitialReads",default:0],7)

        probe.configure(blocked:true)
        let cancelled = (0..<2).map { _ in Task { try await engine.remoteTerminal(sessionID:firstSession.id,initial:true) } }
        try await awaitConnectionCondition {
            RemoteTerminalPerformance.shared.snapshot().counters["sharedInitialReads",default:0] >= actual["sharedInitialReads",default:0]+1 && probe.count == before+4
        }
        cancelled.forEach { $0.cancel() }
        // A fresh caller cannot join a flight whose last browser has cancelled.
        try await awaitConnectionCondition {
            RemoteTerminalPerformance.shared.snapshot().counters["abandonedInitialReads",default:0] >= actual["abandonedInitialReads",default:0]+1
        }
        let replacement = Task { try await engine.remoteTerminal(sessionID:firstSession.id,initial:true) }
        try await awaitConnectionCondition { probe.count == before+5 }
        probe.configure(blocked:false)
        for reader in cancelled {
            do { _ = try await reader.value; throw AppError.message("Cancelled group succeeded") }
            catch is CancellationError {}
        }
        let replacementFrame = try await replacement.value
        try expectEqual(replacementFrame.screen,"Fresh synthetic original "+firstSession.tty)
        try expect(!probe.timedOut)
    }

    func testInitialConnectionDuringInputRejectsOldReadAndRecovers() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aa-initial-input-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let records = ProcessDiscovery.parse("88 1 ttys080 88 88 Tue Sep 22 15:00:00 2026 /usr/local/bin/codex")
        var session = ProcessDiscovery.sessions(records)[0]; session.terminal = .terminal
        let screen = ConnectionReadGate(), writer = ConnectionReadGate()
        let adapter = ScreenHostAdapter(screens:{targets in
            TerminalSnapshot(screens:targets.map { target in _ = screen.read(); return TerminalScreen(tty:target.tty,contents:"Ready") })
        },approve:{_,_,_ in .missingTarget},reveal:{_ in nil},input:{_,_,_,_ in
            _ = writer.read(); return .sent
        },presentationScreens:{targets in
            TerminalSnapshot(screens:targets.map { TerminalScreen(tty:$0.tty,contents:writer.count > 0 ? "After synthetic input" : "Ready") })
        })
        let engine = try ApprovalEngine(paths:AppPaths(directory:directory),processReader:{records},screenAdapters:[.terminal:adapter],terminalInputAvailable:{false})
        defer { screen.configure(blocked:false); engine.stop() }
        engine.updateDiscovery([session],records:records); await engine.connectTerminal()
        let frame = try await engine.remoteTerminal(sessionID:session.id,initial:true)
        try await Task.sleep(for:.milliseconds(2100))
        let before = screen.count; screen.configure(blocked:true)
        let pending = Task { try await engine.remoteTerminal(sessionID:session.id,initial:true) }
        try await awaitConnectionCondition { screen.count == before+1 }
        _ = try await engine.remoteInput(["sessionID":session.id,"revision":frame.revision,"kind":"text","text":"synthetic"])
        screen.configure(blocked:false)
        do { _ = try await pending.value; throw AppError.message("A pre-input first read replaced the current frame") }
        catch let error as RemoteHTTPError {
            try expectEqual(error.status,409); try expectEqual(error.diagnostics?["failureKind"],"observationChanged")
        }
        let recovered = try await RemoteTerminalReadRecovery.read { try await engine.remoteTerminal(sessionID:session.id,initial:true) }
        try expectEqual(recovered.screen,"After synthetic input"); try expectEqual(writer.count,1)
        try expect(!screen.timedOut)
    }
}
