import Foundation
import AutoApproveCore

extension ApprovalTests {
    func testManualPermissionReachesGroupInboxOnFirstFrame() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let record = ProcessDiscovery.parse("993901 1 ttys990 993901 993901 Wed Oct 28 22:00:00 2026 /fixture/claude")[0]
        let leader = SessionGroupMember(agent: .codex, title: "parent", cwd: "/tmp", conversationID: UUID().uuidString)
        var member = SessionGroupMember(agent: .claude, title: "worker", cwd: "/tmp", conversationID: UUID().uuidString)
        member.runtimeID = record.key
        let group = SessionGroup(name: "fixture", members: [leader, member], leaderMemberID: leader.id)
        try SessionGroupStore(directory: directory).save([group])
        let work = SessionGroupAssignment(groupID: group.id, workerMemberID: member.id, parentMemberID: leader.id,
            workerSessionID: record.key, parentSessionID: "fixture-parent", task: "fixture task")
        var state = SessionGroupOrchestration(assignments: [work])
        state.markDelivered(work.id)
        let paths = AppPaths(directory: directory)
        try AuditStore(path: paths.database).set(SessionGroupOrchestration.storeKey, String(decoding: JSONEncoder().encode(state), as: UTF8.self))
        let box = try SessionGroupMailbox(directory: directory)
        let engine = try ApprovalEngine(paths: paths, claudeRegistryReader: { _ in [] }, processReader: { [record] }, isolateByDefault: true)
        defer { engine.stop() }
        var session = AgentSession(id: record.key, agent: .claude, pid: record.pid, started: record.started,
            tty: "/dev/" + record.tty, cwd: "/tmp", terminal: .iterm)
        session.channel = .itermScreen
        engine.updateDiscovery([session], records: [record])
        _ = try engine.sessionGroupAssignments()
        let raw = "Do you want to proceed?\n$ echo fixture\n❯ 1. Yes\n  2. No\nEsc to cancel"
        func observe(_ text: String) { engine.receiveScreen(sessionID: record.key, raw: text, generation: "fixture", source: .itermScreen) }
        func inbox() throws -> [SessionGroupMessage] { try box.list(groupID: group.id, memberID: leader.id, includeAcknowledged: true) }
        try engine.setPaused(true)
        observe(raw)
        try expect(try inbox().isEmpty)
        try engine.setPaused(false)
        try engine.setAutomatic(record.key, enabled: true)
        observe(raw.replacingOccurrences(of: "echo fixture", with: "echo automatic"))
        try expect(try inbox().isEmpty)
        try engine.setAutomatic(record.key, enabled: false)
        observe(raw)
        let message = try inbox().first
        try expectEqual(message?.category, .permissionRequest)
        try expectEqual(message?.senderID, member.id)
        try expect(message?.text.contains("echo fixture") == true)
        observe(raw)
        try expectEqual(try inbox().count, 1)
        observe(raw.replacingOccurrences(of: "echo fixture", with: "echo second"))
        try expectEqual(try inbox().count, 2)
    }

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
        let mixed = ["idle", "request", "working"]
        let mixedIntervals = ["idle": 4.0, "request": 0.5, "working": 2.0]
        let recent = ["idle": 5.9, "request": 9.9, "working": 7.6]
        try expectEqual(RemoteTerminalPolling.monitorBatch(mixed, pending: ["request"], intervals: mixedIntervals,
            lastRead: recent, now: 10, limit: 1), ["request"])
        try expectEqual(RemoteTerminalPolling.monitorBatch(mixed, pending: ["request"], intervals: mixedIntervals,
            lastRead: recent.merging(["idle": 1.0]) { _, new in new }, now: 10, limit: 1), ["idle"])
        try expectEqual(RemoteTerminalPolling.monitorBatch(mixed, pending: [], intervals: mixedIntervals,
            lastRead: recent.merging(["request": 9.0]) { _, new in new }, now: 10, limit: 1), ["request"])
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
