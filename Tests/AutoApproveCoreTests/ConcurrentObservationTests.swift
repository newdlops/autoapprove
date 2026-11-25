import Foundation
import AutoApproveCore

final class ObservationReadGate: @unchecked Sendable {
    private let lock = NSLock()
    private var batches: [[String]] = []
    private let releases: [DispatchSemaphore]

    init(blocking count: Int) {
        releases = (0..<count).map { _ in DispatchSemaphore(value: 0) }
    }

    var reads: [[String]] { lock.withLock { batches } }

    func enter(_ batch: [String]) throws -> Int {
        let index = lock.withLock { batches.append(batch); return batches.count - 1 }
        if index < releases.count, releases[index].wait(timeout: .now() + 8) != .success {
            throw AppError.message("Observation read did not resume")
        }
        return index
    }

    func release(_ index: Int) { releases[index].signal() }

    func waitForReads(_ count: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while reads.count < count {
            guard ContinuousClock.now < deadline else { throw AppError.message("Missing observation read") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    var adapter: ScreenHostAdapter {
        ScreenHostAdapter(screens: { targets in
            let index = try self.enter(targets.map(\.tty).sorted())
            return .init(screens: targets.map { .init(tty: $0.tty, contents: "fixture", title: "read-\(index)") })
        }, approve: { _, _, _ in .missingTarget }, reveal: { _ in nil })
    }
}

extension ApprovalTests {
    private var observationRecords: [ProcessRecord] {
        ProcessDiscovery.parse("""
        21091 1 ttys091 21091 21091 Wed Oct 28 22:00:00 2026 /fixture/claude
        21092 1 ttys092 21092 21092 Wed Oct 28 22:01:00 2026 /fixture/claude
        21093 1 ttys093 21093 21093 Wed Oct 28 22:02:00 2026 /fixture/claude
        """)
    }

    func testOverlappingRefreshWaitsForDiscovery() async throws {
        let gate = ObservationReadGate(blocking: 1), records = observationRecords
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = try ApprovalEngine(paths: .init(directory: directory), claudeRegistryReader: { _ in [] },
            processReader: { _ = try gate.enter([]); return records }, isolateByDefault: true)
        defer { gate.release(0); engine.stop() }
        let first = Task { await engine.refresh() }
        try await gate.waitForReads(1)
        let waiters = (0..<8).map { _ in Task { () -> Bool in
            await engine.refresh()
            return engine.initialDiscoveryComplete && engine.snapshot.sessions.contains { $0.id == records[0].key }
        } }
        await Task.yield()
        try await Task.sleep(for: .milliseconds(50))
        gate.release(0)
        await first.value
        for waiter in waiters { try expect(await waiter.value) }
        try expectEqual(gate.reads.count, 1)
    }

    func testSelectedRefreshRunsAcrossHostsAndKeepsQueuedTabs() async throws {
        let slow = ObservationReadGate(blocking: 1), fast = ObservationReadGate(blocking: 0)
        let records = observationRecords, directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = try ApprovalEngine(paths: .init(directory: directory), claudeRegistryReader: { _ in [] },
            processReader: { records }, screenAdapters: [.terminal: slow.adapter, .iterm: fast.adapter], isolateByDefault: true)
        defer { slow.release(0); engine.stop() }
        await engine.connectScreenHost(.terminal); await engine.connectScreenHost(.iterm)
        var live = ProcessDiscovery.sessions(records).sorted { $0.pid < $1.pid }
        for index in live.indices { live[index].terminal = index == 2 ? .iterm : .terminal }
        engine.updateDiscovery(live, records: records, claudeRegistrations: [])
        let mixed = Task { await engine.refresh(sessionIDs: [live[0].id, live[2].id]) }
        try await slow.waitForReads(1)
        try await fast.waitForReads(1)
        let same = Task { await engine.refresh(sessionIDs: [live[0].id]) }
        let other = Task { await engine.refresh(sessionIDs: [live[1].id]) }
        try await Task.sleep(for: .milliseconds(50))
        try expectEqual(slow.reads, [[live[0].tty]])
        slow.release(0)
        await mixed.value; await same.value; await other.value
        try expectEqual(slow.reads, [[live[0].tty], [live[1].tty]])
        try expectEqual(fast.reads, [[live[2].tty]])
    }

    func testReconnectDiscardsOldGenerationAndCompletes() async throws {
        let gate = ObservationReadGate(blocking: 2), records = observationRecords
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = try ApprovalEngine(paths: .init(directory: directory), claudeRegistryReader: { _ in [] },
            processReader: { records }, screenAdapters: [.terminal: gate.adapter], isolateByDefault: true)
        defer { gate.release(0); gate.release(1); engine.stop() }
        var live = ProcessDiscovery.sessions(records)
        for index in live.indices { live[index].terminal = .terminal }
        engine.updateDiscovery(live, records: records, claudeRegistrations: [])
        let old = Task { await engine.connectScreenHost(.terminal) }
        try await gate.waitForReads(1)
        engine.disconnectScreenHost(.terminal)
        let current = Task { await engine.connectScreenHost(.terminal) }
        await Task.yield()
        gate.release(0)
        try await gate.waitForReads(2)
        await old.value
        try expect(!engine.snapshot.health.screen(.terminal).connected)
        try expect(!engine.snapshot.sessions.contains { $0.terminalTitle == "read-0" })
        gate.release(1)
        await current.value
        try expect(engine.snapshot.health.screen(.terminal).connected)
        try expect(engine.snapshot.sessions.filter { live.map(\.id).contains($0.id) }.allSatisfy { $0.terminalTitle == "read-1" })
        try expectEqual(gate.reads.count, 2)
    }
}
