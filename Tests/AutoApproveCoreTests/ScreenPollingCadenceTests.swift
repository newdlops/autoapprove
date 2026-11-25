import Foundation
import AutoApproveCore

extension ApprovalTests {
    func testScreenPollingCadenceIsPerSession() throws {
        let question = RemoteTerminalPolling.sessionInterval(priorityInput: false, automatic: true, awaitingAnswer: true,
            interrupted: false, active: false, unchangedReads: 0)
        let idle = RemoteTerminalPolling.sessionInterval(priorityInput: false, automatic: true, awaitingAnswer: false,
            interrupted: false, active: false, unchangedReads: 0)
        let stableActive = RemoteTerminalPolling.sessionInterval(priorityInput: false, automatic: true, awaitingAnswer: false,
            interrupted: false, active: true, unchangedReads: 16)
        try expectEqual(question, 0.5); try expectEqual(idle, 3); try expectEqual(stableActive, 2.5)
        try expectEqual(RemoteTerminalPolling.sessionInterval(priorityInput: false, automatic: true, awaitingAnswer: false,
            composerDraft: true, interrupted: false, active: false, unchangedReads: 0), 2, "An unsent draft cannot be approved")
        try expectEqual(RemoteTerminalPolling.sessionInterval(priorityInput: false, automatic: true, awaitingAnswer: true,
            composerDraft: true, interrupted: false, active: false, unchangedReads: 0), 0.5, "A pending question wins over a draft")
        try expectEqual(RemoteTerminalPolling.sessionInterval(priorityInput: true, automatic: false, awaitingAnswer: false,
            interrupted: false, active: false, unchangedReads: 0), 0.35, "Input in flight stays fastest")
        try expectEqual(RemoteTerminalPolling.sessionInterval(priorityInput: false, automatic: false, awaitingAnswer: true,
            interrupted: false, active: false, unchangedReads: 0), 4, "Manual sessions keep the former manual cadence")

        let tabIDs = (0..<24).map { "tab-\($0)" }
        var intervals: [String: TimeInterval] = [:]
        for (index, id) in tabIDs.enumerated() { intervals[id] = index == 0 ? question : index < 10 ? stableActive : idle }
        var lastRead: [String: TimeInterval] = [:], reads: [String: Int] = [:]
        var now: TimeInterval = 1000, passes = 0
        let end = now + 10
        while now < end {
            let due = RemoteTerminalPolling.dueTargets(tabIDs, intervals: intervals, lastRead: lastRead, now: now)
            for id in due { lastRead[id] = now; reads[id, default: 0] += 1 }
            passes += 1
            now += RemoteTerminalPolling.nextReadDelay(tabIDs, intervals: intervals, lastRead: lastRead, now: now)
        }
        let total = reads.values.reduce(0, +)
        try expect((18...22).contains(reads["tab-0"] ?? 0), "The question tab keeps its 0.5 s cadence: \(reads["tab-0"] ?? 0)")
        try expect((4...5).contains(reads["tab-1"] ?? 0), "Active tabs read about every 2.5 s: \(reads["tab-1"] ?? 0)")
        try expect((3...4).contains(reads["tab-23"] ?? 0), "Idle tabs read about every 3 s: \(reads["tab-23"] ?? 0)")
        try expect(total <= 120, "24 tabs need at most 120 reads in 10 s, not 480: \(total)")
        try expect(passes <= 25, "Neighbouring cadences share a pass: \(passes)")

        try expectEqual(RemoteTerminalPolling.dueTargets(["new"], intervals: [:], lastRead: [:], now: now), ["new"])
        try expectEqual(RemoteTerminalPolling.nextReadDelay([], intervals: [:], lastRead: [:], now: now), 8)
        try expectEqual(RemoteTerminalPolling.nextReadDelay(["late"], intervals: ["late": 0.5], lastRead: ["late": 0], now: now), 0.1)
        var pending = Set(tabIDs), readAt: [String:TimeInterval] = [:]
        for pass in 0..<3 {
            let batch = RemoteTerminalPolling.monitorBatch(tabIDs, pending:pending, intervals:[:], lastRead:readAt, now:Double(pass), limit:8)
            try expectEqual(batch.count,8)
            try expect(pending.isSuperset(of:batch))
            pending.subtract(batch)
            for id in batch { readAt[id] = Double(pass) }
        }
        try expect(pending.isEmpty)
        var size = RemoteTerminalPolling.BatchSize()
        try expectEqual(size.limit, 2)
        for _ in 0..<6 { size.completed(count:size.limit, elapsed:0.3) }
        try expectEqual(size.limit, 8)
        size.completed(count:8, elapsed:4)
        try expectEqual(size.limit, 3)
        size.timedOut(count:3)
        try expectEqual(size.limit, 1)
        for _ in 0..<3 { size.completed(count:0, elapsed:0) }
        try expectEqual(size.limit, 1)
        for _ in 0..<3 { size.completed(count:1, elapsed:0.3) }
        try expectEqual(size.limit, 2)
    }
}
