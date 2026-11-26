import Foundation
import CSQLite
#if DEBUG
@testable import AutoApproveCore
#else
import AutoApproveCore
#endif
import TerminalInputSupport

private let pastedStatusInput = "\u{1b}[200~/status\u{1b}[201~\r"

private func groupMCPProof(_ session: AgentSession, id: String, owner: String, home: String = "/fixture/home") -> JSONObject {
    ["owner": owner, "agentKind": "codex", "conversationID": id, "codexCallerConversationID": id,
     "codexCallerRuntimeID": session.id, "codexCallerHome": home, "codexCallerSource": "codex_mcp_metadata"]
}

private final class CodexGroupScreen: @unchecked Sendable {
    let lock = NSLock(), id = UUID().uuidString.lowercased()
    private var value = "Codex\n› Ask Codex to do anything\n  ? for shortcuts"
    private var writes: [String] = []
    var rejectNextFrame = false
    private var resumeWrites = 0
    private var rollout: String?
    init(_ initial: String? = nil) { if let initial { value = initial } }
    func clearRollout() { lock.lock(); defer { lock.unlock() }; rollout = nil }
    func setRollout(_ id: String) { lock.lock(); defer { lock.unlock() }; rollout = id }
    func location() -> CodexThreadLocation? {
        lock.lock(); defer { lock.unlock() }
        return rollout.map { .init(threadID: $0, database: "/fixture/home/thread_history_1.sqlite") }
    }
    var screen: String { lock.lock(); defer { lock.unlock() }; return value }
    func setScreen(_ text: String) { lock.lock(); defer { lock.unlock() }; value = text }
    var inputs: [String] { lock.lock(); defer { lock.unlock() }; return writes }
    var resumes: Int { lock.lock(); defer { lock.unlock() }; return resumeWrites }
    func resume() -> ResumeDelivery { lock.lock(); defer { lock.unlock() }; resumeWrites += 1; return .typed }
    func send(_ input: RemoteTerminalInput) -> TerminalDelivery {
        lock.lock(); defer { lock.unlock() }
        if rejectNextFrame { rejectNextFrame = false; return .screenChanged }
        writes.append(input.bytes)
        if input.bytes.contains("/status") {
            let footer = value.contains("Goal stalled") ? " · Goal stalled (/goal resume)" : ""
            value += "\n>_ OpenAI Codex (v0.169.0)\nModel: fixture\nDirectory: /project\nPermissions: Read Only\nAgents.md: none\nSession: \(id)\n› Ask Codex to do anything\n  ? for shortcuts" + footer
        }
        return .sent
    }
}

private final class GroupProcessSnapshot:@unchecked Sendable {
    private let lock=NSLock()
    private var records:[ProcessRecord]=[]
    func set(_ records:[ProcessRecord]) {lock.withLock{self.records=records}}
    func read()->[ProcessRecord] {lock.withLock{records}}
}

private final class ClippedGroupStatus: @unchecked Sendable {
    let lock = NSLock(), id = UUID().uuidString.lowercased()
    let repeated: Bool, append: Bool
    private var sent = false, reads = 0
    init(repeated: Bool, append: Bool = true) { self.repeated = repeated; self.append = append }
    private var card: String { ">_ OpenAI Codex (v0.169.0)\nModel: fixture\nDirectory: /project\nPermissions: Read Only\nAgents.md: none\nSession: \(id)\n› \n ? for shortcuts" }
    var screen: String {
        lock.lock(); defer { lock.unlock() }
        return repeated || (sent && !append) ? card : sent ? "Session: \(id)\n› \n ? for shortcuts" : "Codex\n• Working (esc to interrupt)\n› \n ? for shortcuts"
    }
    var history: String {
        lock.lock(); defer { lock.unlock() }; reads += 1
        return card + (sent && append ? "\n" + card : "")
    }
    var historyReads: Int { lock.lock(); defer { lock.unlock() }; return reads }
    func send(_ input: RemoteTerminalInput) -> TerminalDelivery {
        lock.lock(); defer { lock.unlock() }
        if input.bytes == "/status\r" { sent = true }
        return .sent
    }
}

private final class GroupInputCooldown: @unchecked Sendable {
    private let lock = NSLock()
    private var started: Date?
    let continuous: Bool
    init(continuous: Bool) { self.continuous = continuous }
    func activate() { lock.lock(); defer { lock.unlock() }; started = Date() }
    var idleSeconds: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        guard let started else { return .infinity }
        return continuous ? 0 : Date().timeIntervalSince(started)
    }
}

private final class GroupObservationReads: @unchecked Sendable {
    let records: [ProcessRecord]
    private let lock = NSLock()
    private var value = 0
    init(_ records: [ProcessRecord]) { self.records = records }
    func read() -> [ProcessRecord] { lock.lock(); value += 1; lock.unlock(); Thread.sleep(forTimeInterval: 0.02); return records }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}

extension ApprovalTests {
    func testCodexGroupGoalPermissionUsesWorkerKeyboardTarget() async throws {
        let records = ProcessDiscovery.parse("""
        88201 1 ttys891 88201 88201 Wed Oct 28 12:00:00 2026 /fixture/codex
        88202 1 ttys892 88202 88202 Wed Oct 28 12:00:01 2026 /fixture/codex
        """)
        let sessions = records.map { AgentSession(id: $0.key, agent: .codex, pid: $0.pid, started: $0.started,
            tty: "/dev/" + $0.tty, cwd: "/project", terminal: .terminal) }
        let leaderThread = UUID().uuidString.lowercased(), workerThread = UUID().uuidString.lowercased()
        let target = CodexReplyTarget(executable: "/fixture/codex", home: "/fixture/home", threadID: workerThread)
        let transport = CodexReplyTransport(prepare: { _,_ in target }, send: { _,_ in throw CancellationError() },
            prepareMessage: { _ in target })
        let goal = CodexGoal(threadId: workerThread, objective: "Fixture", status: .active, createdAt: 1, updatedAt: 1,
            instanceID: UUID().uuidString)
        actor Goals {
            var value: CodexGoal?
            init(_ value: CodexGoal) { self.value = value }
            func clear() { value = nil }
        }
        for activeTTY in [sessions[0].tty, sessions[1].tty, nil] {
            let goals = Goals(goal)
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let keyboard = NativeKeyboardActivity(idleSeconds: { 0 }, frontmostBundle: { ScreenHost.terminal.bundleID },
                inputTargetTTY: { _ in activeTTY })
            let engine = try ApprovalEngine(paths: .init(directory: directory), questionTransport: transport,
                processReader: { records },
                codexGroupReader: { .init(threadID: $0.pid == records[0].pid ? leaderThread : workerThread, database: "/fixture/home/state.sqlite") },
                codexGroupEnvironment: { _ in ["CODEX_HOME":"/fixture/home"] }, nativeKeyboardActivity: keyboard,
                codexGoals: .init(read: { _,_ in await goals.value }, change: { _,_,_,_ in await goals.clear(); return nil }))
            defer { engine.stop(); try? FileManager.default.removeItem(at: directory) }
            engine.updateDiscovery(sessions, records: records)
            let leader = SessionGroupLiveSession(session: sessions[0], conversationID: leaderThread, providerHome: target.home).member
            let worker = SessionGroupLiveSession(session: sessions[1], conversationID: workerThread, providerHome: target.home).member
            let group = SessionGroup(name: "Fixture", members: [leader, worker], leaderMemberID: leader.id)
            try SessionGroupStore(directory: directory).save([group])
            var request = groupMCPProof(sessions[0], id: leaderThread, owner: UUID().uuidString)
            request["tool"] = "manage_group_member_goal"
            request["groupID"] = group.id.uuidString
            request["memberID"] = worker.id.uuidString
            request["action"] = "clear"
            request["threadID"] = workerThread
            request["goalRevision"] = goal.revision
            if activeTTY == sessions[0].tty {
                _ = try await engine.mcpAction(request)
                try expectNil(await goals.value)
            } else {
                do {
                    _ = try await engine.mcpAction(request)
                    throw AppError.message("An active or unknown keyboard target must keep its Goal")
                } catch let error as RemoteHTTPError {
                    try expectEqual(error.diagnostics?["delivery"], "not_started")
                    try expect(error.message.contains("입력"))
                    try expectEqual(await goals.value, goal)
                }
            }
        }
    }

    func testCodexMCPIdentitySurvivesHistoricalWelcomeWithoutLosingResetSafety() async throws {
        for host in [ScreenHost.terminal, .iterm] {
            let directory = URL(fileURLWithPath: "/private/tmp/aa-status-banner-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let record = ProcessDiscovery.parse("100591 1 fixture40 100591 100591 Wed Oct 28 12:00:00 2026 /fixture/codex")[0]
            var session = AgentSession(id: record.key, agent: .codex, pid: record.pid, started: record.started, tty: "/dev/" + record.tty, cwd: "/project", terminal: host.kind)
            session.channel = host.channel
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = .current; formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
            let identity = TTYInputIdentity(pid: record.pid, processGroup: record.pid, uid: getuid(), effectiveUID: geteuid(), device: 42,
                startSeconds: UInt64(formatter.date(from: record.started)!.timeIntervalSince1970), startMicroseconds: 71)
            let welcome = ">_ OpenAI Codex (v0.169.0)\n  /project"
            let composer = "\n› Ask Codex to do anything\n  ? for shortcuts"
            let screen = CodexGroupScreen(welcome + composer)
            var adapter = ScreenHostAdapter(screens: { targets in .init(screens: targets.map { .init(tty: $0.tty, contents: screen.screen) }) },
                approve: { _, _, _ in .missingTarget }, reveal: { _ in nil }, input: { _, _, _, input in screen.send(input) })
            adapter.backgroundInput = adapter.input
            let engine = try ApprovalEngine(paths: .init(directory: directory), processReader: { [record] }, screenAdapters: [host: adapter],
                terminalInputAvailable: { true }, terminalInputIdentity: { _ in identity }, codexGroupReader: { _ in nil },
                codexGroupEnvironment: { _ in ["CODEX_HOME": "/fixture/home"] })
            defer { engine.stop() }
            engine.updateDiscovery([session], records: [record]); await engine.connectScreenHost(host)
            engine.receiveScreen(sessionID: session.id, raw: screen.screen, generation: "same-cli")
            let group = SessionGroup(name: "fixture", members: [SessionGroupLiveSession(session: session, conversationID: nil, providerHome: "/fixture/home").member])
            try SessionGroupStore(directory: directory).save([group])
            var proof = groupMCPProof(session, id: screen.id, owner: UUID().uuidString)
            proof["tool"] = "get_session_groups"
            _ = try await engine.mcpAction(proof)
            let saved = try SessionGroupStore(directory: directory).load()[0]
            try expectNotNil(SessionGroupMatching.match(saved.members[0], in: try await engine.sessionGroupSessions()))
            let completed = welcome + "\n• Completed the synthetic task." + composer
            for frame in [
                welcome + "\n• Working (esc to interrupt)\n› \n ? for shortcuts",
                completed,
                completed + " · 90% context left",
                "Old output\n" + completed,
                welcome + "\nTip: Use /help.\n• Completed another task." + composer,
                welcome + "\n› earlier user request\ncompleted reply" + composer
            ] {
                screen.setScreen(frame); engine.receiveScreen(sessionID: session.id, raw: frame, generation: "same-cli")
                let live = try await engine.sessionGroupSessions()
                try expectEqual(live.first?.conversationID, screen.id, "Historical welcome headers must preserve the verified UUID")
                try expectNotNil(SessionGroupMatching.match(saved.members[0], in: live))
            }
            try expectEqual(screen.inputs, [], "Observing normal work must not type into the terminal")
            // A real clear/new screen has only a fresh header, directory and composer.
            // Keep membership but stop using the old conversation for delivery.
            let boxed = "╭──────────────────────────────────────╮\n│ >_ OpenAI Codex (v0.169.0)            │\n│ model: fixture                       │\n│ directory: /project                  │\n╰──────────────────────────────────────╯\nTip: Use /help."
            for frame in [welcome + composer,
                          welcome + "\n› \n100% left",
                          welcome + "\n› \nGPT-6.1-Sol max · ~/project · Ready · Context 35% left",
                          boxed + composer] {
                if try await engine.sessionGroupSessions().first?.conversationID == nil {
                    _ = try await engine.mcpAction(proof)
                }
                let inputs = screen.inputs.count
                screen.setScreen(frame)
                engine.receiveScreen(sessionID: session.id, raw: frame, generation: "same-cli")
                let reset = try await engine.sessionGroupSessions()
                try expectNil(reset.first?.conversationID)
                try expectNil(SessionGroupMatching.match(saved.members[0], in: reset))
                try expectNotNil(SessionGroupMatching.connection(saved.members[0], in: reset))
                try expectEqual(try SessionGroupStore(directory: directory).load(), [saved], "A possible reset must not delete group membership")
                try expectEqual(screen.inputs.count, inputs)
            }
        }
    }

#if DEBUG
    func testGroupIdentityObservationsCoalesceConcurrentReaders() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp/aa-group-observation-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let records = ProcessDiscovery.parse("900002 1 ttys902 900002 900002 Mon Nov 16 10:00:00 2026 /fixture/codex")
        let reads = GroupObservationReads(records), record = records[0], id = UUID().uuidString.lowercased()
        let engine = try ApprovalEngine(paths: AppPaths(directory: directory), processReader: { reads.read() },
            codexGroupReader: { _ in .init(threadID: id, database: "/fixture/home/thread_history_1.sqlite") },
            codexGroupEnvironment: { _ in ["CODEX_HOME": "/fixture/home"] })
        defer { engine.stop() }
        engine.updateDiscovery([AgentSession(id: record.key, agent: .codex, pid: record.pid, started: record.started, tty: "/dev/" + record.tty, cwd: "/fixture", terminal: .terminal)], records: records)
        let before = reads.count
        async let first = engine.sessionGroupSessions()
        async let second = engine.sessionGroupSessions()
        async let third = engine.sessionGroupSessions()
        let values = try await [first, second, third]
        try expect(values.allSatisfy { $0.count == 1 && $0[0].conversationID == id })
        try expectEqual(reads.count - before, 2, "Concurrent queries share one observation with before/after process witnesses")
        _ = try await engine.sessionGroupSessions()
        try expectEqual(reads.count - before, 4, "A later query must read fresh identity rather than a stale cache")
    }

    func testCodexLiveIdentityRetriesOnlyMissingHeaders() throws {
        let root = URL(fileURLWithPath: "/private/tmp/aa-codex-identity-retry-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("sessions/2026/11/17")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let first = directory.appendingPathComponent("rollout-first.jsonl"), second = directory.appendingPathComponent("rollout-second.jsonl")
        let a = UUID().uuidString.lowercased(), b = UUID().uuidString.lowercased()
        func header(_ id: String) throws -> Data {
            var data = try JSONSerialization.data(withJSONObject: ["type": "session_meta", "payload": ["source": "cli", "id": id]])
            data.append(10); return data
        }
        let record = ProcessDiscovery.parse("900001 1 ttys901 900001 900001 Mon Nov 16 10:00:00 2026 /fixture/codex")[0]
        var reads = 0
        let found = try CodexThreadLocation.locateLive(record, paths: { current in
            try expectEqual(current.key, record.key); reads += 1
            if reads == 2 { try header(a).write(to: first) }
            return [first.path]
        })
        try expectEqual(reads, 2); try expectEqual(found.threadID, a)
        try header(b).write(to: second)
        reads = 0
        do {
            _ = try CodexThreadLocation.locateLive(record, paths: { _ in reads += 1; return [first.path, second.path] })
            throw AppError.message("Ambiguous roots were accepted")
        } catch CodexThreadLocationFailure.ambiguous {}
        try expectEqual(reads, 1, "Ambiguity is never resolved by retrying until a convenient answer appears")
        reads = 0
        do {
            _ = try CodexThreadLocation.locateLive(record, paths: { _ in reads += 1; throw POSIXError(.ESTALE) })
            throw AppError.message("A replaced process was accepted")
        } catch let error as POSIXError { try expectEqual(error.code, .ESTALE) }
        try expectEqual(reads, 1)
        reads = 0
        do {
            _ = try CodexThreadLocation.locateLive(record, paths: { _ in reads += 1; return [directory.appendingPathComponent("rollout-pending.jsonl").path] })
            throw AppError.message("A previous UUID was adopted after a missing header")
        } catch CodexThreadLocationFailure.missing {}
        try expectEqual(reads, 3, "Missing metadata has a bounded retry budget")
        reads = 0
        do {
            _ = try CodexThreadLocation.locateLive(record, paths: { _ in reads += 1; return [] })
            throw AppError.message("An absent rollout was guessed")
        } catch CodexThreadLocationFailure.missing {}
        try expectEqual(reads, 1, "Managed clients without rollouts must not pay a retry delay every poll")
    }
#endif
    @MainActor func testCodexGroupStatusWaitsForInputCooldownWithoutBypass() async throws {
        for continuous in [false, true] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("codex-status-cooldown-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let record = ProcessDiscovery.parse("100597 1 fixture46 100597 100597 Wed Oct 28 12:00:00 2026 /fixture/codex")[0]
            let session = AgentSession(id: record.key, agent: .codex, pid: record.pid, started: record.started, tty: "/dev/" + record.tty, cwd: "/project", terminal: .terminal)
            let screen = CodexGroupScreen(), priority = GroupInputCooldown(continuous: continuous)
            screen.rejectNextFrame = true
            var adapter = ScreenHostAdapter(screens: { targets in TerminalSnapshot(screens: targets.map { TerminalScreen(tty: $0.tty, contents: screen.screen) }) },
                approve: { _, _, _ in .missingTarget }, reveal: { _ in nil }, input: { _, _, _, input in
                    try expect(priority.idleSeconds >= 1.5, "Never input during keyboard priority")
                    return screen.send(input)
                })
            adapter.backgroundInput = adapter.input
            let engine = try ApprovalEngine(paths: AppPaths(directory: directory), processReader: { [record] }, screenAdapters: [.terminal: adapter],
                codexGroupReader: { _ in nil }, codexGroupEnvironment: { _ in ["CODEX_HOME": "/fixture/home"] },
                nativeKeyboardActivity: .init(idleSeconds: { priority.idleSeconds }, frontmostBundle: { "com.apple.Terminal" }))
            defer { engine.stop() }
            engine.updateDiscovery([session], records: [record]); await engine.connectScreenHost(.terminal)
            let previousID = UUID().uuidString.lowercased()
            let group = SessionGroup(name: "fixture", members: [SessionGroupLiveSession(session: session, conversationID: previousID, providerHome: "/fixture/home").member])
            try SessionGroupStore(directory: directory).save([group]); priority.activate()
            var succeeded = false
            do { try expectEqual(try await engine.statusConversationID(session), screen.id); succeeded = true }
            catch {
                if !continuous { throw error }
                try expect(error.localizedDescription.contains("키보드"), "Explain real input priority, not an invented terminal question")
            }
            try expectEqual(succeeded, !continuous)
            try expectEqual(screen.inputs, continuous ? [] : ["/status\r"])
            try expectEqual(try SessionGroupStore(directory: directory).load()[0].members[0].conversationID, previousID)
        }
    }
    @MainActor func testCodexGroupStatusUsesFreshHistoryWhenFrameClips() async throws {
        for (repeated, append) in [(false, true), (true, true), (false, false)] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("codex-status-history-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let record = ProcessDiscovery.parse("100596 1 fixture45 100596 100596 Wed Oct 28 12:00:00 2026 /fixture/codex")[0]
            let session = AgentSession(id: record.key, agent: .codex, pid: record.pid, started: record.started, tty: "/dev/" + record.tty, cwd: "/project", terminal: .terminal)
            let screen = ClippedGroupStatus(repeated: repeated, append: append)
            var adapter = ScreenHostAdapter(screens: { targets in TerminalSnapshot(screens: targets.map { TerminalScreen(tty: $0.tty, contents: screen.screen) }) },
                approve: { _, _, _ in .missingTarget }, reveal: { _ in nil }, input: { _, _, _, input in screen.send(input) },
                history: { target in try expectEqual(target.tty, session.tty); return screen.history })
            adapter.backgroundInput = adapter.input
            let engine = try ApprovalEngine(paths: AppPaths(directory: directory), processReader: { [record] }, screenAdapters: [.terminal: adapter],
                codexGroupReader: { _ in nil }, codexGroupEnvironment: { _ in ["CODEX_HOME": "/fixture/home"] })
            defer { engine.stop() }
            engine.updateDiscovery([session], records: [record]); await engine.connectScreenHost(.terminal)
            let group = SessionGroup(name: "fixture", members: [SessionGroupLiveSession(session: session, conversationID: nil, providerHome: "/fixture/home").member])
            try SessionGroupStore(directory: directory).save([group])
            _ = try await engine.sessionGroupSessions()
            try expectEqual(screen.historyReads, 0, "Discovery never reads scrollback")
            var refreshed = false
            do { try expectEqual(try await engine.statusConversationID(session), screen.id); refreshed = true }
            catch { if append { throw error } }
            try expectEqual(refreshed, append, "An unchanged historical card must never establish freshness")
            let saved = try SessionGroupStore(directory: directory).load()[0]
            try expectEqual(saved.members[0].conversationID, "")
            try expect(screen.historyReads <= 4, "History fallback is bounded per explicit query")
        }
    }
    @MainActor func testCodexGroupStatusRefreshDuringRecoveryReview() async throws {
        for useITerm in [false, true] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("codex-group-review-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let record = ProcessDiscovery.parse("100594 1 fixture43 100594 100594 Wed Oct 28 12:00:00 2026 /fixture/codex")[0]
            let host: ScreenHost = useITerm ? .iterm : .terminal
            var session = AgentSession(id: record.key, agent: .codex, pid: record.pid, started: record.started, tty: "/dev/" + record.tty, cwd: "/project", terminal: useITerm ? .iterm : .terminal)
            session.channel = host.channel
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current; formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
            let identity = TTYInputIdentity(pid: record.pid, processGroup: record.pid, uid: getuid(), effectiveUID: geteuid(), device: 42,
                startSeconds: UInt64(formatter.date(from: record.started)!.timeIntervalSince1970), startMicroseconds: 71)
            let text = "Codex\n› Ask Codex to do anything\n ? for shortcuts · Goal stalled (/goal resume)"
            let screen = CodexGroupScreen(text)
            var adapter = ScreenHostAdapter(screens: { targets in TerminalSnapshot(screens: targets.map { TerminalScreen(tty: $0.tty, contents: screen.screen) }) },
                approve: { _, _, _ in .missingTarget }, reveal: { _ in nil }, resume: { _, _, _ in screen.resume() }, input: { _, _, _, input in screen.send(input) })
            adapter.backgroundInput = adapter.input
            let engine = try ApprovalEngine(paths: AppPaths(directory: directory), processReader: { [record] }, screenAdapters: [host: adapter],
                terminalInputAvailable: { true }, terminalInputIdentity: { _ in identity },
                codexGroupReader: { _ in nil }, codexGroupEnvironment: { _ in ["CODEX_HOME": "/fixture/home"] })
            defer { engine.stop() }
            engine.goalBlockedResumeDelays = [0.01]
            engine.updateDiscovery([session], records: [record]); try engine.setAutomatic(session.id, enabled: true)
            await engine.connectScreenHost(host)
            engine.receiveScreen(sessionID: session.id, raw: text, generation: "fixture")
            for _ in 0..<100 {
                if engine.snapshot.sessions.first?.capacityResume?.phase == .review { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            engine.receiveScreen(sessionID: session.id, raw: text, generation: "fixture")
            try expectEqual(screen.resumes, 1)
            try expectEqual(engine.snapshot.sessions.first?.interruption?.resumeUncertain, true)
            try expectEqual(engine.snapshot.sessions.first?.pendingInTerminal, true)
            try expect(engine.snapshot.sessions.first?.pendingRequestID?.hasPrefix("capacity:review:") == true)
            if !useITerm {
                let frame = try await engine.remoteTerminal(sessionID: session.id, realtime: true)
                var rejected = false
                do {
                    _ = try await engine.remoteInput(["sessionID": session.id, "revision": frame.revision, "streamID": frame.streamID ?? "",
                        "relay": true, "kind": "message", "text": "/status", "codexStatusQuery": true])
                } catch { rejected = true }
                try expect(rejected, "Public JSON cannot grant the private status-query capability")
                try expectEqual(screen.inputs.count, 0)
            }
            let group = SessionGroup(name: "fixture", members: [SessionGroupLiveSession(session: session, conversationID: nil, providerHome: "/fixture/home").member])
            try SessionGroupStore(directory: directory).save([group])
            _ = try await engine.sessionGroupSessions()
            try expectEqual(screen.inputs.count, 0, "Observation must never queue a status command")
            try expectEqual(try await engine.statusConversationID(session), screen.id)
            try expectEqual(screen.inputs, [useITerm ? pastedStatusInput : "/status\r"])
            try expectEqual(screen.resumes, 1, "A read-only status query must never retry /goal resume")
            try expectEqual(engine.snapshot.sessions.first?.interruption?.resumeUncertain, true)
            try expectNil(engine.snapshot.sessions.first?.interruption?.recoveredAt)
        }
    }

    @MainActor func testCodexGroupStatusReviewDoesNotBypassRealInput() async throws {
        let screens = [
            "Codex\n› my unfinished draft\n ? for shortcuts · Goal stalled (/goal resume)",
            "Would you like to make the following edits?\n› 1. Yes, proceed (y)\n  2. No (esc)\nPress enter to confirm or esc to cancel"
        ]
        for text in screens {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("codex-group-review-busy-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let record = ProcessDiscovery.parse("100595 1 fixture44 100595 100595 Wed Oct 28 12:00:00 2026 /fixture/codex")[0]
            var session = AgentSession(id: record.key, agent: .codex, pid: record.pid, started: record.started, tty: "/dev/" + record.tty, cwd: "/project", terminal: .iterm)
            session.phase = .idle; session.pendingInTerminal = true; session.pendingRequestID = "capacity:review:fixture"
            let screen = CodexGroupScreen(text)
            let adapter = ScreenHostAdapter(screens: { targets in TerminalSnapshot(screens: targets.map { TerminalScreen(tty: $0.tty, contents: screen.screen) }) },
                approve: { _, _, _ in .missingTarget }, reveal: { _ in nil }, input: { _, _, _, input in screen.send(input) })
            let engine = try ApprovalEngine(paths: AppPaths(directory: directory), processReader: { [record] }, screenAdapters: [.iterm: adapter])
            defer { engine.stop() }
            await engine.connectScreenHost(.iterm); engine.updateDiscovery([session], records: [record])
            let group = SessionGroup(name: "fixture", members: [SessionGroupLiveSession(session: session, conversationID: nil, providerHome: "/fixture/home").member])
            try SessionGroupStore(directory: directory).save([group])
            var rejected = false
            do { _ = try await engine.statusConversationID(session) } catch { rejected = true }
            try expect(rejected); try expectEqual(screen.inputs.count, 0)
            try expectEqual(try SessionGroupStore(directory: directory).load()[0].members[0].conversationID, "")
        }
    }

    @MainActor func testRestoredLeaderRecoversFromCallingTab() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let oldRecords = ProcessDiscovery.parse("""
        900 1 fixture40 900 901 Wed Oct 28 10:00:00 2026 /bin/zsh
        901 900 fixture40 901 901 Wed Oct 28 10:01:00 2026 /fixture/codex
        """)
        let newRecords = ProcessDiscovery.parse("""
        910 1 fixture41 910 911 Wed Oct 28 12:00:00 2026 /bin/zsh
        911 910 fixture41 911 911 Wed Oct 28 12:01:00 2026 /fixture/codex
        """)
        let tab = UUID().uuidString, oldID = UUID().uuidString.lowercased(), newID = UUID().uuidString.lowercased()
        let store = SessionGroupStore(directory: directory)
        func open(_ rows: [ProcessRecord], _ id: String, _ tabID: String) throws -> ApprovalEngine {
            let engine = try ApprovalEngine(paths: .init(directory: directory), processReader: { rows },
                codexGroupReader: { _ in .init(threadID: id, database: "/fixture/home/state.sqlite") },
                codexGroupEnvironment: { _ in ["CODEX_HOME": "/fixture/home", "TERM_SESSION_ID": tabID] })
            let p = rows[1]
            engine.updateDiscovery([AgentSession(id: p.key, agent: .codex, pid: p.pid, started: p.started,
                tty: "/dev/" + p.tty, cwd: "/project", terminal: .terminal)], records: rows)
            return engine
        }
        let old = try open(oldRecords, oldID, tab)
        let member = try await old.sessionGroupSessions()[0].member
        let group = SessionGroup(name: "saved", members: [member], leaderMemberID: member.id)
        try store.save([group])
        old.stop()
        func call(_ tool: String, _ engine: ApprovalEngine) async throws -> JSONObject {
            try await engine.mcpAction(["tool": tool, "owner": UUID().uuidString, "sessionID": newRecords[1].key,
                "conversationID": newID, "groupID": group.id.uuidString, "memberID": member.id.uuidString])
        }
        let unrelated = try open(newRecords, newID, UUID().uuidString)
        let invisible = try await call("get_session_groups", unrelated)
        try expectEqual((invisible["groups"] as? [JSONObject])?.count, 0)
        unrelated.stop()
        let restored = try open(newRecords, newID, tab)
        defer { restored.stop() }
        let listed = try await call("get_session_groups", restored)
        let row = ((listed["groups"] as? [JSONObject])?.first?["members"] as? [JSONObject])?.first
        try expectEqual(row?["isCaller"] as? Bool, true)
        try expectEqual(row?["canReconnect"] as? Bool, true)
        try expectEqual(try store.load()[0].members[0].conversationID, newID)
        let repaired = try await call("reconnect_group_member", restored)
        try expectEqual(repaired["conversationID"] as? String, newID)
        try expectEqual(try store.load()[0].leaderMemberID, member.id)
        let status = try await call("get_group_status", restored)
        try expectEqual((status["groups"] as? [JSONObject])?.count, 1)
    }

    @MainActor func testCodexReplacementPreservesGroupRoleAndValidatesTabLifetime() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let shell = ProcessDiscovery.parse("900 1 fixture40 900 901 Wed Oct 28 12:00:00 2026 /bin/zsh")[0]
        let old = ProcessDiscovery.parse("901 900 fixture40 901 901 Wed Oct 28 12:01:00 2026 /fixture/codex")[0]
        let new = ProcessDiscovery.parse("902 900 fixture40 902 902 Wed Oct 28 12:02:00 2026 /fixture/codex")[0]
        let records = GroupProcessSnapshot()
        let oldID = UUID().uuidString.lowercased(), newID = UUID().uuidString.lowercased(), home = "/fixture/home"
        func session(_ p: ProcessRecord) -> AgentSession {
            AgentSession(id: p.key, agent: .codex, pid: p.pid, started: p.started, tty: "/dev/" + p.tty, cwd: "/project", terminal: .terminal)
        }
        let engine = try ApprovalEngine(paths: .init(directory: directory), processReader: { records.read() },
            codexGroupReader: { .init(threadID: $0.pid == old.pid ? oldID : newID, database: home + "/state.sqlite") },
            codexGroupEnvironment: { _ in ["CODEX_HOME":home] })
        defer { engine.stop() }
        records.set([shell,old]); engine.updateDiscovery([session(old)], records: records.read())
        let original = try await engine.sessionGroupSessions()[0].member
        let duplicate = SessionGroupLiveSession(session: session(new), conversationID: newID, providerHome: home).member
        let store = SessionGroupStore(directory: directory)
        let group = SessionGroup(name: "fixture", members: [original, duplicate], leaderMemberID: original.id)
        try store.save([group])
        func refresh() async throws -> SessionGroupIdentityRefresh {
            try await engine.refreshSessionGroupMemberID(groupID: group.id, memberID: original.id)
        }
        var recycled = shell; recycled.started = "Wed Oct 28 12:02:00 2026"
        records.set([recycled,new]); engine.updateDiscovery([session(new)], records: records.read())
        do { _ = try await refresh(); throw AppError.message("Recycled TTY accepted") }
        catch { try expect(error.localizedDescription.contains("원래 터미널")) }
        records.set([shell,new])
        let result = try await refresh()
        try expectEqual(result.conversationID, newID); try expectEqual(result.mergedMemberID, duplicate.id)
        let updated = try store.load()[0]
        try expectEqual(updated.leaderMemberIDs,[original.id]); try expectEqual(updated.members.map(\.id), [original.id])
        try expectEqual(updated.members[0].runtimeID,new.key)
        var legacy = original; legacy.tabShell = nil
        let flat = SessionGroup(id: group.id, name: group.name, members: [legacy, duplicate])
        try store.save([flat])
        do { _ = try await refresh(); throw AppError.message("Unproven replacement accepted") }
        catch { try expect(error.localizedDescription.contains("원래 터미널")) }
        do {
            _ = try await engine.refreshSessionGroupMemberID(groupID: group.id, memberID: original.id,
                                                             selectedReplacement: new.key, expectedConversationID: oldID)
            throw AppError.message("Changed conversation accepted")
        } catch { try expect(error.localizedDescription.contains("대화가 바뀌었습니다")) }
        try store.save([flat.addingLeader(duplicate.id)])
        do {
            _ = try await engine.refreshSessionGroupMemberID(groupID: group.id, memberID: original.id, selectedReplacement: new.key)
            throw AppError.message("Duplicate leader removed")
        } catch { try expect(error.localizedDescription.contains("다른 구성원")) }
        try expectEqual(try store.load()[0].leaderMemberIDs,[duplicate.id])
        try store.save([flat])
        let manual = try await engine.refreshSessionGroupMemberID(groupID: group.id, memberID: original.id, expectedGroup: flat,
                                                                  selectedReplacement: new.key, expectedConversationID: newID)
        try expectEqual(manual.mergedMemberID, duplicate.id)
    }

    @MainActor func testCodexNamedGroupRefreshAndRepeatedCard() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("group-name-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let record = ProcessDiscovery.parse("100599 1 fixture48 100599 100599 Wed Oct 28 12:00:00 2026 /fixture/codex")[0]
        let session = AgentSession(id: record.key, agent: .codex, pid: record.pid, started: record.started, tty: "/dev/" + record.tty, cwd: "/project", terminal: .terminal)
        let screen = CodexGroupScreen("Codex\n› unfinished draft\n ? for shortcuts")
        let card = ">_ OpenAI Codex (v0.169.0)\nModel: fixture\nDirectory: /project\nPermissions: Read Only\nAgents.md: none\nSession: " + screen.id
        let marker = "• Current working directory: /project"
        let footer = "\n› Ask Codex to do anything\n  ? for shortcuts"
        var db: OpaquePointer?
        try expectEqual(sqlite3_open(home.appendingPathComponent("state_5.sqlite").path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        func sql(_ query: String) throws { try expectEqual(sqlite3_exec(db, query, nil, nil, nil), SQLITE_OK) }
        try sql("CREATE TABLE threads(id TEXT, name TEXT, cwd TEXT, archived INTEGER)")
        try sql("INSERT INTO threads VALUES('\(screen.id)','고유 이름','/project',0)")
        let reply = CodexReplyTransport(prepare: { _,_ in throw AppError.message("unexpected prepare") }, send: { _,_ in throw AppError.message("unexpected send") },
            queueHome: { _ in .init(executable: "", home: home.path, threadID: "") })
        let queue = CodexQueueTransport(list: { _ in [] }, delete: { _,_ in .init(removed: []) }, validate: { target, cwd in
            try expectEqual(target.threadID, screen.id); try expectEqual(target.home, home.path); try expectEqual(cwd, "/project")
        })
        var adapter = ScreenHostAdapter(screens: { targets in .init(screens: targets.map { .init(tty: $0.tty, contents: screen.screen, title: "고유 이름 | project") }) },
            approve: { _,_,_ in .missingTarget }, reveal: { _ in throw AppError.message("unexpected focus") }, history: { _ in screen.screen })
        adapter.backgroundInput = { _,_,_,input in
            _ = screen.send(input)
            switch input.text {
            case "/pwd": screen.setScreen(card + "\n" + marker + footer)
            case "/status": screen.setScreen(marker + "\n" + card + footer)
            default: throw AppError.message("unexpected input")
            }
            return .sent
        }
        let engine = try ApprovalEngine(paths: .init(directory: home), questionTransport: reply, processReader: { [record] }, screenAdapters: [.terminal: adapter],
            codexQueue: queue, codexGroupReader: { _ in nil }, codexGroupEnvironment: { _ in ["CODEX_HOME": home.path] }, nativeKeyboardActivity: .inactive)
        defer { engine.stop() }
        engine.updateDiscovery([session], records: [record]); await engine.connectScreenHost(.terminal)
        let group = SessionGroup(name: "fixture", members: [SessionGroupLiveSession(session: session, conversationID: nil, providerHome: home.path).member])
        try SessionGroupStore(directory: home).save([group])
        func refresh() async throws -> String {
            try await engine.refreshSessionGroupMemberID(groupID: group.id, memberID: group.members[0].id).conversationID
        }
        let captured = try await engine.terminalProfileSaveCandidates(readWindowLayout: false)
        guard let candidate = captured.first, candidate.canQueryConversation else { throw AppError.message("Missing profile lookup") }
        try expectEqual(candidate.entry.conversationID, "")
        let resolved = try await engine.resolveProfileConversation(candidate)
        try expectEqual(resolved.entry.conversationID, screen.id)
        try expectEqual(resolved.entry.id, candidate.entry.id)
        let validated = try await engine.terminalProfileSaveCandidates(readWindowLayout: false, sessionIDs: [session.id])
        try expectEqual(validated.first?.entry.conversationID, screen.id)
        try expectNil(try await engine.sessionGroupSessions().first?.conversationID)
        engine.receiveScreen(sessionID: session.id, raw: ">_ OpenAI Codex (v0.169.0)\nmodel: fixture\ndirectory: /project" + footer, generation: "fixture-reset", source: .terminalScreen)
        let reset = try await engine.terminalProfileSaveCandidates(readWindowLayout: false, sessionIDs: [session.id])
        try expectEqual(reset.first?.entry.conversationID, "")
        try expect(screen.inputs.isEmpty)
        try expectEqual(try await refresh(), screen.id)
        try expect(screen.inputs.isEmpty, "Named session is identified without touching the draft")
        try sql("INSERT INTO threads VALUES('\(UUID().uuidString)','고유 이름','/project',0)")
        do { _ = try await refresh(); throw AppError.message("Duplicate name accepted") }
        catch { try expect(error.localizedDescription.contains("입력")) }
        try expect(screen.inputs.isEmpty)
        do { _ = try await engine.resolveProfileConversation(candidate); throw AppError.message("Duplicate title accepted for profile") }
        catch { try expect(error.localizedDescription.contains("입력")) }
        try expect(screen.inputs.isEmpty)
        screen.setScreen(card + footer)
        try expectEqual(try await engine.resolveProfileConversation(candidate).entry.conversationID, screen.id, "Repeated status card identifies the selected tab")
        try expectEqual(screen.inputs, ["/pwd\r", "/status\r"])
    }

    @MainActor func testCodexGroupRefreshPrefersLocalHistoryAndUsesBoundMCP() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("codex-group-evidence-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let record = ProcessDiscovery.parse("100591 1 fixture40 100591 100591 Wed Oct 28 12:00:00 2026 /fixture/codex")[0]
        var session = AgentSession(id: record.key, agent: .codex, pid: record.pid, started: record.started,
                                   tty: "/dev/" + record.tty, cwd: "/project", terminal: .iterm)
        session.phase = .working
        let screen = CodexGroupScreen("Codex\n› unfinished draft\n ? for shortcuts")
        let adapter = ScreenHostAdapter(screens: { targets in .init(screens: targets.map { .init(tty: $0.tty, contents: screen.screen) }) },
            approve: { _, _, _ in .missingTarget }, reveal: { _ in throw AppError.message("Refresh switched tabs") }, input: { _, _, _, input in screen.send(input) })
        let engine = try ApprovalEngine(paths: AppPaths(directory: directory), processReader: { [record] }, screenAdapters: [.iterm: adapter],
            codexGroupReader: { _ in screen.location() }, codexGroupEnvironment: { _ in ["CODEX_HOME": "/fixture/home"] })
        defer { engine.stop() }
        engine.updateDiscovery([session], records: [record]); await engine.connectScreenHost(.iterm)
        let member = SessionGroupLiveSession(session: session, conversationID: nil, providerHome: "/fixture/home").member
        let group = SessionGroup(name: "fixture", members: [member]); let store = SessionGroupStore(directory: directory)
        try store.save([group])
        func refresh() async throws -> SessionGroupIdentityRefresh {
            try await engine.refreshSessionGroupMemberID(groupID: group.id, memberID: member.id)
        }
        func observe(_ proof: JSONObject) async throws {
            var call = proof; call["tool"] = "get_session_groups"
            _ = try await engine.mcpAction(call)
        }
        func checkUnavailable(storedID: String) async throws {
            var rejected = false
            do { _ = try await refresh() }
            catch { rejected = error.localizedDescription.contains("입력") }
            try expect(rejected)
            try expectEqual(try store.load()[0].members[0].conversationID, storedID)
        }
        let owner = UUID().uuidString, mcpID = UUID().uuidString.lowercased()
        var unbound = groupMCPProof(session, id: mcpID, owner: owner)
        unbound.removeValue(forKey: "codexCallerRuntimeID")
        try await observe(unbound)
        try await checkUnavailable(storedID: "")
        var inherited = groupMCPProof(session, id: mcpID, owner: owner)
        inherited["codexCallerSource"] = "codex_exec_context"
        try await observe(inherited)
        try await checkUnavailable(storedID: "")
        try await observe(groupMCPProof(session, id: mcpID, owner: owner, home: "/fixture/other"))
        try await checkUnavailable(storedID: "")

        screen.setRollout(screen.id)
        try await observe(groupMCPProof(session, id: mcpID, owner: owner))
        try expectEqual(try await refresh().conversationID, screen.id, "Verified local history wins over a different MCP UUID")
        try expectEqual(try store.load()[0].members[0].conversationID, screen.id)
        screen.clearRollout()
        try expectEqual(try await refresh().conversationID, mcpID, "Only this runtime's own MCP receipt may supply a missing rollout")
        try expectEqual(try store.load()[0].members[0].conversationID, mcpID)

        let conflictingOwner = UUID().uuidString
        try await observe(groupMCPProof(session, id: UUID().uuidString, owner: conflictingOwner))
        try await checkUnavailable(storedID: mcpID)
        _ = try await engine.mcpAction(["tool": "disconnect", "owner": conflictingOwner])
        try expectEqual(try await refresh().conversationID, mcpID)
        _ = try await engine.mcpAction(["tool": "disconnect", "owner": owner])
        try await checkUnavailable(storedID: mcpID)
        try expectEqual(screen.inputs, [], "Refresh must not write anything into the Codex composer")
    }

    @MainActor func testCodexGroupDiscoveryPreservesBusyScreensAndDrafts() async throws {
        for text in ["Codex\n• Working (esc to interrupt)\n› \n  ? for shortcuts", "Codex\n› my unfinished draft\n  ? for shortcuts"] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("codex-group-busy-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let record = ProcessDiscovery.parse("100592 1 fixture41 100592 100592 Wed Oct 28 12:00:00 2026 /fixture/codex")[0]
            let session = AgentSession(id: record.key, agent: .codex, pid: record.pid, started: record.started, tty: "/dev/" + record.tty, cwd: "/project", terminal: .iterm)
            let screen = CodexGroupScreen(text)
            let adapter = ScreenHostAdapter(screens: { targets in TerminalSnapshot(screens: targets.map { TerminalScreen(tty: $0.tty, contents: screen.screen) }) },
                approve: { _, _, _ in .missingTarget }, reveal: { _ in nil }, input: { _, _, _, input in screen.send(input) })
            let engine = try ApprovalEngine(paths: AppPaths(directory: directory), processReader: { [record] }, screenAdapters: [.iterm: adapter],
                codexGroupReader: { _ in nil }, codexGroupEnvironment: { _ in ["CODEX_HOME": "/fixture/home"] })
            defer { engine.stop() }
            engine.updateDiscovery([session], records: [record]); await engine.connectScreenHost(.iterm)
            _ = try await engine.sessionGroupSessions()
            try await Task.sleep(for: .milliseconds(500))
            try expectEqual(screen.inputs.count, 0)
            try expectEqual(screen.screen, text)
        }
    }
    func testCodexGroupMCPMetadata() throws {
        let id = UUID().uuidString, other = UUID().uuidString
        let message: JSONObject = ["params": ["arguments": ["conversationID": other], "_meta": [
            "threadId": id, "x-codex-turn-metadata": ["thread_id": id.lowercased(), "session_id": id]]]]
        try expectEqual(try CodexGroupIdentity.conversationID(in: message), id.lowercased())
        try expectEqual(try CodexGroupIdentity.conversationID(in: message, environment: ["CODEX_THREAD_ID": other]), id.lowercased(), "Per-call metadata wins over inherited context")
        try expectEqual(try CodexGroupIdentity.conversationID(in: [:], environment: ["CODEX_THREAD_ID": id]), id.lowercased())
        try expectNil(try CodexGroupIdentity.conversationID(in: [:], environment: ["CODEX_THREAD_ID": "invalid"]))
        try expectNil(try CodexGroupIdentity.conversationID(in: ["params": ["arguments": ["CODEX_THREAD_ID": id]]]))
        try expectNil(try CodexGroupIdentity.conversationID(in: ["params": ["arguments": ["_meta": ["threadId": id]]]]))
        try expect(CodexGroupIdentity.allowsTerminalAttribution(message))
        for fields: JSONObject in [["parent_thread_id": other], ["subagent_kind": "thread_spawn"], ["thread_source": "subagent"]] {
            let turn = fields.merging(["thread_id": id], uniquingKeysWith: { original, _ in original })
            let subagent: JSONObject = ["params": ["_meta": ["x-codex-turn-metadata": turn]]]
            try expectEqual(try CodexGroupIdentity.conversationID(in: subagent), id.lowercased())
            try expectFalse(CodexGroupIdentity.allowsTerminalAttribution(subagent))
        }
        for meta: JSONObject in [["threadId": "bad"], ["threadId": id, "x-codex-turn-metadata": ["thread_id": other]]] {
            do { _ = try CodexGroupIdentity.conversationID(in: ["params": ["_meta": meta]]); throw AppError.message("Accepted ambiguous metadata") }
            catch let error as AppError { try expect(error.localizedDescription.contains("서로 다릅니다")) }
        }
    }

    func testLeaderDuplicateNameRepair() throws {
        let session = AgentSession(id: "old", agent: .claude, pid: 10, started: "before", tty: "/dev/t1", cwd: "/fixture", terminal: .terminal)
        let old = SessionGroupLiveSession(session: session, conversationID: UUID().uuidString.lowercased(), providerHome: "/home", messagingName: "leader")
        var child = old
        child.session.id = "new"
        child.session.tty = "/dev/t2"
        child.conversationID = UUID().uuidString.lowercased()
        let leader = old.member, duplicate = child.member
        let group = SessionGroup(name: "fixture", members: [leader, duplicate], leaderMemberID: leader.id)
        try expectEqual(SessionGroupMatching.identityWarnings(group, live: [old, child]).count, 2)
        let fixed = try SessionGroupMatching.restoringLeader(leader.id, from: duplicate.id, in: group, target: child)
        try expectEqual(fixed.leaderMemberIDs, [leader.id])
        try expectEqual(SessionGroupMatching.match(fixed.members[0], in: [old, child])?.id, child.id)
        try expectNil(SessionGroupMatching.match(fixed.members[1], in: [old, child]))
        try expectEqual(fixed.members[1].id, duplicate.id)
        try expect(SessionGroupMatching.identityWarnings(fixed, live: [old, child]).isEmpty)
    }

    @MainActor func testBulkRefreshSwappedTerminals() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let records = ProcessDiscovery.parse("""
        100801 1 fixture81 100801 100801 Wed Oct 28 12:00:00 2026 /fixture/codex
        100802 1 fixture82 100802 100802 Wed Oct 28 12:00:00 2026 /fixture/codex
        """)
        let ids = records.map { _ in UUID().uuidString.lowercased() }
        let current = Dictionary(uniqueKeysWithValues: zip(records.map(\.pid), ids))
        let engine = try ApprovalEngine(paths: .init(directory: directory), processReader: { records },
            codexGroupReader: { record in current[record.pid].map { .init(threadID: $0, database: "/fixture/home/state.sqlite") } },
            codexGroupEnvironment: { _ in ["CODEX_HOME": "/fixture/home"] })
        defer { engine.stop() }
        let sessions = records.map { AgentSession(id: $0.key, agent: .codex, pid: $0.pid, started: $0.started,
            tty: "/dev/" + $0.tty, cwd: "/project", terminal: .terminal) }
        engine.updateDiscovery(sessions, records: records)
        let members = zip(sessions, ids.reversed()).map { SessionGroupLiveSession(session: $0.0, conversationID: $0.1, providerHome: "/fixture/home").member }
        let original = SessionGroup(name: "fixture", members: members, leaderMemberID: members[0].id)
        let store = SessionGroupStore(directory: directory)
        try store.save([original])
        let updated = try await engine.refreshGroupTerminals(original)
        try expectEqual(updated.members.map(\.conversationID), ids)
        try expectEqual(updated.members.map(\.id), members.map(\.id))
        try expectEqual(updated.leaderMemberID, original.leaderMemberID)
        try expectEqual(try store.load(), [updated])
        let repeated = try await engine.refreshGroupTerminals(updated)
        try expectEqual(repeated, updated)
    }

    func testGroupRefreshFollowsCurrentTerminal() throws {
        for agent in [AgentKind.codex, .claude, .agy] {
            let oldID = UUID(), freshID = UUID()
            let original = AgentSession(id: "original", agent: agent, pid: 10, started: "a", tty: "/dev/a", cwd: "/project", terminal: .terminal)
            let sameTab = SessionGroupLiveSession(session: original, conversationID: freshID.uuidString, providerHome: "/home")
            var member = sameTab.member
            member.conversationID = oldID.uuidString
            member.nickname = "시험도구 검증"
            try expect(member.diagnosticLabel.contains("시험도구 검증") && member.diagnosticLabel.contains(member.id.uuidString.prefix(8)))
            var other = sameTab
            other.session.id = "another"
            other.conversationID = oldID.uuidString
            let group = SessionGroup(name: "group", members: [member])
            let both = [sameTab, other]
            try expectFalse(SessionGroupMatching.permitsIdentityRefresh(member, candidate: other, conversation: oldID, live: both))
            try expect(SessionGroupMatching.permitsIdentityRefresh(member, candidate: sameTab, conversation: freshID, live: both))
            let auto = agent == .codex ? CodexGroupIdentity.refreshed([group], live: both) : SessionGroupMatching.refreshedClaude([group], live: both)
            try expectEqual(auto[0].members[0].conversationID, freshID.uuidString.lowercased())
            try expectEqual(auto[0].members[0].runtimeID, sameTab.id)
            var peer = other.member
            peer.conversationID = freshID.uuidString
            let swapped = SessionGroup(name: "swap", members: [member, peer], leaderMemberID: member.id)
            let repaired = agent == .codex ? CodexGroupIdentity.refreshed([swapped], live: both) : SessionGroupMatching.refreshedClaude([swapped], live: both)
            try expectEqual(repaired[0].members.map { UUID(uuidString: $0.conversationID) }, [freshID, oldID])
            try expectEqual(repaired[0].leaderMemberID, member.id)
            try expect(SessionGroupMatching.permitsIdentityRefresh(member, candidate: sameTab, conversation: freshID, live: [sameTab]))
            other.conversationID = freshID.uuidString
            try expectFalse(SessionGroupMatching.permitsIdentityRefresh(member, candidate: sameTab, conversation: freshID, live: [sameTab, other]))
        }
    }

    func testClaudeLeaderResumeThenClear() throws {
        let conversation = UUID().uuidString.lowercased()
        let session = AgentSession(id: "process:21:new", agent: .claude, pid: 21, started: "new", tty: "/dev/ttys001", cwd: "/project", terminal: .terminal)
        var endpoint = SessionGroupLiveSession(session: session, conversationID: conversation, providerHome: "/home/claude")
        var member = endpoint.member
        member.runtimeID = "process:20:old"
        let group = SessionGroup(name: "fixture", members: [member], leaderMemberID: member.id)
        var duplicate = endpoint
        duplicate.session.id = "process:22:other"
        try expectEqual(SessionGroupMatching.refreshedClaude([group], live: [endpoint, duplicate]), [group])
        let resumed = SessionGroupMatching.refreshedClaude([group], live: [endpoint])[0]
        try expectEqual(resumed.members[0].runtimeID, endpoint.id)
        endpoint.conversationID = UUID().uuidString.lowercased()
        let cleared = SessionGroupMatching.refreshedClaude([resumed], live: [endpoint])[0]
        try expectEqual(cleared.members[0].conversationID, endpoint.conversationID)
        try expectEqual(cleared.leaderMemberID, member.id)
    }

    func testCodexGroupRefreshIsolatedFromClaude() throws {
        let old = UUID().uuidString, new = UUID().uuidString
        let session = AgentSession(id: "process:123:start", agent: .codex, pid: 123, started: "start", tty: "/dev/ttys001", cwd: "/project", terminal: .terminal)
        let live = SessionGroupLiveSession(session: session, conversationID: new, providerHome: "/home/codex")
        var member = live.member; member.conversationID = old
        var claude = member; claude.id = UUID(); claude.agent = .claude
        let group = SessionGroup(name: "fixture", members: [member, claude]).settingLeader(member.id)
        let updated = CodexGroupIdentity.refreshed([group], live: [live])[0]
        try expectEqual(updated.members[0].conversationID, new.lowercased())
        try expectEqual(updated.members[1], claude)
        try expectEqual(updated.leaderMemberID, member.id)
        var restarted = live; restarted.session.id = "process:456:new-start"; restarted.session.pid = 456
        try expectEqual(CodexGroupIdentity.refreshed([updated], live: [restarted])[0].members[0].runtimeID, restarted.id)
        restarted.session.cwd = "/resumed/elsewhere"
        try expectEqual(CodexGroupIdentity.refreshed([updated], live: [restarted])[0].members[0].runtimeID, restarted.id)
        let moved = CodexGroupIdentity.refreshed([updated], live: [restarted])[0]
        restarted.conversationID = UUID().uuidString
        try expectEqual(CodexGroupIdentity.refreshed([moved], live: [restarted])[0].members[0].conversationID, restarted.conversationID?.lowercased())
        restarted.conversationID = new
        try expectEqual(CodexGroupIdentity.refreshed([group], live: [live, restarted]), [group])
        var foreign = live; foreign.providerHome = "/home/other"
        try expectEqual(CodexGroupIdentity.refreshed([group], live: [foreign]), [group])
        var unknown = live; unknown.conversationID = nil
        try expectEqual(CodexGroupIdentity.refreshed([group], live: [unknown]), [group])
    }

    @MainActor func testCodexSharedMCPFindsSavedGroupWithoutTerminalGuess() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("codex-group-metadata-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID().uuidString, home = "/fixture/codex"
        let member = SessionGroupMember(agent: .codex, title: "fixture", cwd: "/project", conversationID: id, providerHome: home)
        try SessionGroupStore(directory: directory).save([SessionGroup(name: "owned", members: [member])])
        let reader=GroupProcessSnapshot()
        let engine = try ApprovalEngine(paths: AppPaths(directory: directory), processReader: {reader.read()},codexGroupReader:{_ in nil})
        defer { engine.stop() }
        var params: JSONObject = ["owner": UUID().uuidString, "tool": "get_session_groups", "agentKind": "codex",
            "sessionID": "shared-daemon", "conversationID": id, "codexCallerConversationID": id, "codexCallerHome": home]
        let result = try await engine.mcpAction(params)
        let groups = result["groups"] as? [JSONObject]
        try expectEqual(groups?.count, 1)
        let peer = (groups?.first?["members"] as? [JSONObject])?.first
        try expectEqual(peer?["isCaller"] as? Bool, true)
        try expectEqual(peer?["connected"] as? Bool, false, "MCP identity must not invent a terminal connection")
        try expectEqual(peer?["connectionState"] as? String, "disconnected")
        // A shared MCP process may also be observed as an unrelated live CLI.
        // This must not supersede the conversation proven by this call.
        let record = ProcessDiscovery.parse("100599 1 fixture49 100599 100599 Wed Oct 28 12:00:00 2026 /fixture/codex")[0]
        let unrelated = AgentSession(id: record.key, agent: .codex, pid: record.pid, started: record.started,
                                     tty: "/dev/" + record.tty, cwd: "/other", terminal: .unknown)
        reader.set([record])
        engine.updateDiscovery([unrelated], records: [record])
        params["sessionID"] = unrelated.id
        let withUnrelatedProcess = try await engine.mcpAction(params)
        try expectEqual((withUnrelatedProcess["groups"] as? [JSONObject])?.count, 1)
        try expectEqual(withUnrelatedProcess["attribution"] as? String, "codex_mcp_metadata")
        try expect(engine.snapshot.sessions.contains(where:{$0.id==unrelated.id && $0.phase != .ended}),"The unrelated observed process must remain live for this identity regression")
        params["conversationID"] = UUID().uuidString
        do { _ = try await engine.mcpAction(params); throw AppError.message("Accepted mismatched conversation proof") }
        catch let error as RemoteHTTPError { try expectEqual(error.status, 409) }
        params["conversationID"] = id
        params["codexCallerHome"] = "/fixture/other"
        try expectEqual((try await engine.mcpAction(params)["groups"] as? [JSONObject])?.count, 0)
    }

    @MainActor func testCodexMetadataUsesConversationMatchedLiveParentForClaudePermissions() async throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("codex-live-parent-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:directory)}
        let rows=ProcessDiscovery.parse("""
        100595 1 fixture45 100595 100595 Wed Oct 28 12:00:00 2026 /fixture/codex
        100596 1 fixture46 100596 100596 Wed Oct 28 12:00:01 2026 /fixture/claude
        """)
        let parentID=UUID().uuidString,workerID=UUID().uuidString,home="/fixture/home"
        let sessions=rows.map{AgentSession(id:$0.key,agent:$0.agent!,pid:$0.pid,started:$0.started,tty:"/dev/"+$0.tty,cwd:"/project",terminal:.terminal)}
        let engine=try ApprovalEngine(paths:.init(directory:directory),claudeRegistryReader:{records in
            records.filter{$0.pid==rows[1].pid}.map{.init(processID:$0.key,kind:"interactive",sessionID:workerID,status:"idle")}
        },processReader:{rows},codexGroupReader:{_ in .init(threadID:parentID,database:home+"/thread_history_1.sqlite")})
        defer{engine.stop()}
        engine.updateDiscovery(sessions,records:rows)
        let parent=SessionGroupLiveSession(session:sessions[0],conversationID:parentID,providerHome:home).member
        let worker=SessionGroupLiveSession(session:sessions[1],conversationID:workerID,providerHome:nil).member
        let group=SessionGroup(name:"Live conversation parent",members:[parent,worker]).settingLeader(parent.id)
        try SessionGroupStore(directory:directory).save([group])
        let result=try await engine.mcpAction(["owner":UUID().uuidString,"tool":"get_group_status","agentKind":"codex",
            "sessionID":"shared-mcp-host","conversationID":parentID,"codexCallerConversationID":parentID,"codexCallerHome":home])
        let groups=result["groups"] as? [JSONObject],members=groups?.first?["members"] as? [JSONObject]
        try expectEqual(groups?.count,1)
        try expectEqual(members?.first(where:{$0["id"] as? String==worker.id.uuidString})?["canAssign"] as? Bool,true,"A unique conversation-proven live Codex parent keeps its existing Claude task authority")
    }

    func testMCPProcessLanguageEnvironment() throws {
        try expectEqual(MCPProcessEnvironment.locale(environment: [:], preferredLanguages: ["ko-KR"]), "ko_KR.UTF-8")
        try expectEqual(MCPProcessEnvironment.locale(environment: ["LANG": "C", "LC_ALL": "C"], preferredLanguages: ["ko"]), "ko_KR.UTF-8")
        try expectEqual(MCPProcessEnvironment.locale(environment: ["LANG": "ja_JP.UTF-8"], preferredLanguages: ["ko-KR"]), "ja_JP.UTF-8")
        try expectEqual(MCPProcessEnvironment.locale(environment: ["LC_ALL": "en_US.UTF-8", "LANG": "ko_KR.UTF-8"], preferredLanguages: []), "en_US.UTF-8")
        try expectEqual(MCPProcessEnvironment.locale(environment: ["LANG": "bad\nlocale"], preferredLanguages: []), "en_US.UTF-8")
    }

    func testCodexMembershipFollowsConversationAcrossEndpoints() throws {
        let id = UUID().uuidString
        let member = SessionGroupMember(agent: .codex, title: "saved", cwd: "/old", conversationID: id, providerHome: "/home/a")
        let session = AgentSession(id: "new-runtime", agent: .codex, pid: 123, started: "new", tty: "/dev/new", cwd: "/new", terminal: .unknown)
        let live = SessionGroupLiveSession(session: session, conversationID: id, providerHome: "/home/a")
        try expectEqual(SessionGroupMatching.match(member, in: [live])?.id, session.id)
        var wrong = live; wrong.conversationID = UUID().uuidString
        try expectNil(SessionGroupMatching.match(member, in: [wrong]))
        wrong = live; wrong.providerHome = "/home/b"
        try expectNil(SessionGroupMatching.match(member, in: [wrong]))
        var duplicate = live; duplicate.session.id = "other-runtime"
        try expectNil(SessionGroupMatching.match(member, in: [live, duplicate]))
    }

    @MainActor func testCodexMetadataParentCanDirectConfirmedWorker() async throws {
        for (useTerminal, textUnavailable, backgroundAvailable) in [(false, false, true), (false, true, true), (true, false, true), (true, false, false)] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("codex-group-parent-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let parentID = UUID().uuidString, workerID = UUID().uuidString, home = "/fixture/home"
        let parent = SessionGroupMember(agent: .codex, title: "parent", cwd: "/project", conversationID: parentID, providerHome: home)
        let record = ProcessDiscovery.parse("100593 1 fixture42 100593 100593 Wed Oct 28 12:00:00 2026 /fixture/codex")[0]
        let host: ScreenHost = useTerminal ? .terminal : .iterm
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current; formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        let identity = TTYInputIdentity(pid: record.pid, processGroup: record.pid, uid: getuid(), effectiveUID: geteuid(), device: 42,
            startSeconds: UInt64(formatter.date(from: record.started)!.timeIntervalSince1970), startMicroseconds: 71)
        let session = AgentSession(id: record.key, agent: .codex, pid: record.pid, started: record.started, tty: "/dev/" + record.tty, cwd: "/project", terminal: useTerminal ? .terminal : .iterm)
        let screen = CodexGroupScreen()
        var adapter = ScreenHostAdapter(screens: { targets in TerminalSnapshot(screens: targets.map { TerminalScreen(tty: $0.tty, contents: screen.screen) }) },
            approve: { _, _, _ in .missingTarget }, reveal: { _ in nil }, input: { _, _, _, input in
                if useTerminal { throw AppError.message("Focus-dependent input must never be used for group traffic") }
                return screen.send(input)
            },
            presentationScreens: { _ in throw AppError.message("Cursor/window lookup timed out") },
            validationScreens: { targets in
                if textUnavailable { throw AppError.message("Text channel unavailable") }
                return TerminalSnapshot(screens: targets.map { TerminalScreen(tty: $0.tty, contents: screen.screen) })
            })
        if useTerminal, backgroundAvailable {
            adapter.backgroundInput = { target, raw, agent, input in
                try TerminalDeviceInput.deliverBackground(target: target, screen: raw, agent: agent, input: input,
                    captureIdentity: { _ in identity }, run: { script in
                        try expect(!script.contains("activate") && !script.contains("selectedTab=") && !script.contains("selectedTab =") && !script.contains("System Events"), "Group delivery must not select or focus any window")
                        try expect(script.contains("app.doScript(target.text, {in: tab})"))
                        _ = screen.send(input)
                        return "sent"
                    })
            }
        }
        let engine = try ApprovalEngine(paths: AppPaths(directory: directory), processReader: { [record] }, screenAdapters: [host: adapter],
            terminalInputAvailable: { true }, terminalInputIdentity: { _ in identity },
            codexGroupReader: { _ in .init(threadID: workerID, database: home + "/thread_history_1.sqlite") })
        defer { engine.stop() }
        engine.updateDiscovery([session], records: [record]); await engine.connectScreenHost(host)
        let worker = SessionGroupLiveSession(session: session, conversationID: workerID, providerHome: home).member
        let peer = SessionGroupMember(agent: .codex, title: "Other leader", cwd: parent.cwd, conversationID: UUID().uuidString.lowercased(), providerHome: home)
        let group = SessionGroup(name: "fixture", members: [peer, parent, worker], leaderMemberID: peer.id).addingLeader(parent.id)
        try SessionGroupStore(directory: directory).save([group])
        let params: JSONObject = ["owner": UUID().uuidString, "tool": "assign_group_task", "agentKind": "codex",
            "sessionID": "shared-daemon", "conversationID": parentID, "codexCallerConversationID": parentID, "codexCallerHome": home,
            "groupID": group.id.uuidString, "memberID": worker.id.uuidString, "task": "Inspect the fixture"]
        if textUnavailable || !backgroundAvailable {
            do { _ = try await engine.mcpAction(params); throw AppError.message("Unreadable text accepted a task") }
            catch let error as RemoteHTTPError {
                try expectEqual(error.diagnostics?["delivery"], "not_started")
                try expect(error.localizedDescription.contains(textUnavailable ? "Text channel unavailable" : "포커스 없는"), "Unexpected rejection (Terminal: \(useTerminal)): \(error.localizedDescription)")
            }
            try expectEqual(screen.inputs.count, 0)
            try expect(try engine.sessionGroupAssignments().isEmpty)
            continue
        }
        _ = try await engine.mcpAction(params)
        try expectEqual(screen.inputs.count, 1)
        try expect(screen.inputs[0].contains("Inspect the fixture"))
        let task = try engine.sessionGroupAssignments().first
        try expectEqual(task?.workerSessionID, session.id)
        try expectEqual(task?.parentMemberID, parent.id)
        var conflict = params
        conflict["owner"] = UUID().uuidString
        conflict["conversationID"] = peer.conversationID
        conflict["codexCallerConversationID"] = peer.conversationID
        do { _ = try await engine.mcpAction(conflict); throw AppError.message("Peer replaced a working assignment") }
        catch let error as RemoteHTTPError { try expectEqual(error.status, 409) }
        try expectEqual(screen.inputs.count, 1)
        try expectEqual(try engine.sessionGroupAssignments().first?.id, task?.id)
        try expect(task?.parentSessionID.hasPrefix("codex-mcp:") == true, "Never route reports to an unverified parent terminal")
        }
    }

    @MainActor func testCodexGroupRejectsStaleApprovalBinding() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("codex-group-binding-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let record = ProcessDiscovery.parse("100531 1 fixture4 100531 100531 Wed Oct 28 12:00:00 2026 /fixture/codex")[0]
        var session = AgentSession(id: record.key, agent: .codex, pid: record.pid, started: record.started, tty: "/dev/" + record.tty, cwd: "/project", terminal: .terminal)
        session.codexApprovalBinding = .init(threadID: UUID().uuidString, title: "old")
        let engine = try ApprovalEngine(paths: AppPaths(directory: directory), processReader: { [record] }, codexGroupReader: { _ in nil })
        defer { engine.stop() }; engine.updateDiscovery([session], records: [record])
        try expectNil(try await engine.sessionGroupSessions().first?.conversationID)
    }
}

extension ApprovalTests {
    @MainActor func testGroupOfflineReconnectUsesOriginalTerminal() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("aa-group-offline-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let records = ProcessDiscovery.parse("""
        100901 1 fixture91 100901 100901 Wed Oct 28 12:00:00 2026 /fixture/codex
        100902 1 fixture92 100902 100902 Wed Oct 28 12:00:00 2026 /fixture/codex
        100903 1 fixture93 100903 100903 Wed Oct 28 12:00:00 2026 /fixture/codex
        """)
        let ids = records.map { _ in UUID().uuidString.lowercased() }
        let sessions = records.map { AgentSession(id: $0.key, agent: .codex, pid: $0.pid, started: $0.started,
            tty: "/dev/" + $0.tty, cwd: "/project", terminal: .iterm) }
        let screen = CodexGroupScreen("Codex\n• Working (esc to interrupt)\n› \n ? for shortcuts")
        let adapter = ScreenHostAdapter(screens: { targets in TerminalSnapshot(screens: targets.map { TerminalScreen(tty: $0.tty, contents: screen.screen) }) },
            approve: { _, _, _ in .missingTarget }, reveal: { _ in nil }, input: { target, _, _, input in
                try expectEqual(target.tty, sessions[1].tty, "Only the saved worker terminal may be queried")
                return screen.send(input)
            })
        let engine = try ApprovalEngine(paths: AppPaths(directory: directory), processReader: { records }, screenAdapters: [.iterm: adapter],
            codexGroupReader: { record in
                guard record.pid != records[1].pid, let index = records.firstIndex(where: { $0.key == record.key }) else { return nil }
                return .init(threadID: ids[index], database: "/fixture/home/thread_history_1.sqlite")
            }, codexGroupEnvironment: { _ in ["CODEX_HOME": "/fixture/home"] }, isolateByDefault: true)
        defer { engine.stop() }
        try engine.start(poll: false, webByDefault: true)
        engine.updateDiscovery(sessions, records: records); await engine.connectScreenHost(.iterm)
        let members = sessions.enumerated().map { SessionGroupLiveSession(session: $0.element, conversationID: ids[$0.offset], providerHome: "/fixture/home").member }
        let group = SessionGroup(name: "offline", members: Array(members.prefix(2)), leaderMemberID: members[0].id)
        let store = SessionGroupStore(directory: directory); try store.save([group])
        func call(_ tool: String, caller: Int = 0, target: Int = 1, proof: JSONObject = [:]) async throws -> JSONObject {
            let params: JSONObject = ["tool": tool, "owner": UUID().uuidString, "sessionID": sessions[caller].id,
                "conversationID": ids[caller], "groupID": group.id.uuidString, "memberID": members[target].id.uuidString, "task": "Check fixture"]
            return try await Task.detached {
                try SocketClient.request(path: AppPaths(directory: directory).socket,
                    message: ["method": "mcp", "params": params.merging(proof, uniquingKeysWith: { _, current in current })], timeout: 20)
            }.value
        }
        try expect(engine.networkIsolated); try expect(!engine.webStatus.ready)
        let listed = try await call("get_session_groups", caller: 1)
        let rows = (listed["groups"] as? [JSONObject])?.first?["members"] as? [JSONObject]
        try expectEqual(rows?.first { $0["id"] as? String == members[1].id.uuidString }?["connected"] as? Bool, false)
        try expectEqual(rows?.first { $0["id"] as? String == members[1].id.uuidString }?["canReconnect"] as? Bool, true)
        try expectEqual(screen.inputs, [], "Read-only membership must not type /status")
        for (tool, caller, target) in [("reconnect_group_member", 2, 1), ("reconnect_group_member", 1, 0), ("assign_group_task", 0, 1), ("get_group_status", 1, 1)] {
            var rejected = false
            do { _ = try await call(tool, caller: caller, target: target) } catch { rejected = true }
            try expect(rejected, "Unverified or unauthorized operation succeeded")
        }
        try expectEqual(screen.inputs, [])
        // A shared server can report the worker UUID without an owning TTY.
        var shared = groupMCPProof(sessions[1], id: UUID().uuidString, owner: UUID().uuidString)
        shared.removeValue(forKey: "codexCallerRuntimeID")
        _ = try await call("get_session_groups", caller: 1, proof: shared)
        try expectEqual(screen.inputs, [])
        let repaired = try await call("reconnect_group_member")
        try expectEqual(repaired["connected"] as? Bool, true)
        try expectEqual(repaired["conversationID"] as? String, screen.id)
        try expectEqual(repaired["transport"] as? String, "local_terminal")
        try expectEqual(try store.load()[0].members[1].conversationID, screen.id)
        try expectEqual(screen.inputs, [pastedStatusInput], "Only the worker tab may receive /status")
        let same = try await engine.refreshSessionGroupMemberID(groupID: group.id, memberID: members[1].id)
        try expectEqual(same.conversationID, screen.id)
        try expectFalse(same.changed)
        try expectEqual(screen.inputs, [pastedStatusInput, pastedStatusInput], "An explicit refresh must see a new card, even after a verified reconnect")
        _ = try await call("get_session_groups", caller: 1, proof: groupMCPProof(sessions[1], id: screen.id, owner: UUID().uuidString))
        let sent = screen.inputs
        _ = try await call("reconnect_group_member")
        try expectEqual(screen.inputs, sent, "A bound MCP call avoids further terminal input")
        try expect(engine.networkIsolated); try expect(!engine.webStatus.ready)
        // An exited member may not be replaced with an unrelated process in the same project.
        engine.updateDiscovery([sessions[0], sessions[2]], records: [records[0], records[2]])
        var rejected = false
        do { _ = try await call("reconnect_group_member") } catch { rejected = true }
        try expect(rejected, "An exited terminal was guessed")
        try expectEqual(screen.inputs, sent)
    }

    @MainActor func testGroupOfflineSelfReconnectProtectsDrafts() async throws {
        for text in ["Codex\n› unfinished draft\n ? for shortcuts", "Codex\n› Ask Codex to do anything\n ? for shortcuts"] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("group-self-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let record = ProcessDiscovery.parse("100904 1 fixture94 100904 100904 Wed Oct 28 12:00:00 2026 /fixture/codex")[0]
            let session = AgentSession(id: record.key, agent: .codex, pid: record.pid, started: record.started, tty: "/dev/" + record.tty, cwd: "/project", terminal: .iterm)
            let screen = CodexGroupScreen(text)
            let adapter = ScreenHostAdapter(screens: { targets in TerminalSnapshot(screens: targets.map { TerminalScreen(tty: $0.tty, contents: screen.screen) }) },
                approve: { _, _, _ in .missingTarget }, reveal: { _ in nil }, input: { _, _, _, input in screen.send(input) })
            let engine = try ApprovalEngine(paths: AppPaths(directory: directory), processReader: { [record] }, screenAdapters: [.iterm: adapter],
                codexGroupReader: { _ in nil }, codexGroupEnvironment: { _ in ["CODEX_HOME": "/fixture/home"] }, isolateByDefault: true)
            defer { engine.stop() }
            engine.updateDiscovery([session], records: [record]); await engine.connectScreenHost(.iterm)
            let member = SessionGroupLiveSession(session: session, conversationID: UUID().uuidString, providerHome: "/fixture/home").member
            let group = SessionGroup(name: "self", members: [member]); let store = SessionGroupStore(directory: directory); try store.save([group])
            var params = groupMCPProof(session, id: screen.id, owner: UUID().uuidString)
            params["tool"] = "reconnect_group_member"; params["groupID"] = group.id.uuidString; params["memberID"] = member.id.uuidString
            let result = try await engine.mcpAction(params)
            try expectEqual(result["connected"] as? Bool, true)
            try expectEqual(try store.load()[0].members[0].conversationID, screen.id)
            try expectEqual(screen.screen, text)
            try expectEqual(screen.inputs, [])
        }
    }
}
