import Foundation
import Combine
import Darwin
import AutoApproveCore

private final class PollingScreens: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot = TerminalSnapshot()
    func set(_ value: TerminalSnapshot) { lock.lock(); defer { lock.unlock() }; snapshot = value }
    func read() -> TerminalSnapshot { lock.lock(); defer { lock.unlock() }; return snapshot }
}

@MainActor private final class ScreenHeartbeat {
    var ticks = 0
    var previous = ProcessInfo.processInfo.systemUptime
    var largestGap: TimeInterval = 0
    func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        largestGap = max(largestGap, now - previous); previous = now; ticks += 1
    }
    func reset() { previous = ProcessInfo.processInfo.systemUptime; largestGap = 0; ticks = 0 }
}

private final class DelayedLargeScreens: @unchecked Sendable {
    private let lock = NSLock(), release = DispatchSemaphore(value: 0)
    private var delayed = false, entered = false
    let raw = String(repeating: "synthetic unchanged scrollback /fixture/output.swift\n", count: 30_000)
        + "Would you like to run the following command?\n$ touch ~/Library/LaunchAgents/com.fixture.late.plist\n› 1. Yes\n  2. No\nEsc to cancel"
    func arm() { lock.lock(); delayed = true; lock.unlock() }
    var waiting: Bool { lock.lock(); defer { lock.unlock() }; return entered }
    func finish() { release.signal() }
    func read(_ targets: [ScreenTarget]) -> TerminalSnapshot {
        lock.lock(); let wait = delayed; if wait { entered = true }; lock.unlock()
        if wait { _ = release.wait(timeout: .now() + 3) }
        return TerminalSnapshot(screens: targets.map { TerminalScreen(tty: $0.tty, contents: wait ? raw : "Working\nesc to interrupt") })
    }
}

extension ApprovalTests {
    func testRepeatedWebFramesBoundParsingAndKeepChangedQuestions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aa-web-frame-reuse-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let record = ProcessDiscovery.parse("420000 1 ttys099 420000 420000 Mon Oct 5 09:00:00 2026 codex")[0]
        let session = AgentSession(id: record.key, agent: .codex, pid: record.pid, started: record.started,
            tty: "/dev/ttys099", cwd: root.path, terminal: .iterm)
        let history = String(repeating: "Synthetic scrollback /fixture/output.swift: preserved original output.\n", count: 2_500)
        let menu = "Which synthetic screen should we inspect?\n\n› 1. Phone layout\n  2. Desktop layout\n\nPress enter to confirm or esc to cancel"
        let frames = PollingScreens()
        func replace(_ raw: String) { frames.set(TerminalSnapshot(screens: [TerminalScreen(tty: session.tty, contents: raw)])) }
        replace(history + menu)
        let adapter = ScreenHostAdapter(screens: { _ in frames.read() }, approve: { _, _, _ in .missingTarget }, reveal: { _ in nil })
        let engine = try ApprovalEngine(paths: AppPaths(directory: root), claudeRegistryReader: { _ in [] },
            processReader: { [record] }, screenAdapters: [.iterm: adapter], terminalInputAvailable: { false })
        defer { engine.stop() }
        engine.updateDiscovery([session], records: [record]); await engine.connectScreenHost(.iterm)
        let first = try await engine.remoteTerminal(sessionID: session.id, realtime: true)
        try expectEqual(first.question?.options, ["Phone layout", "Desktop layout"])
        func cpu() -> Double {
            var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
            return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
                + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        }
        let started = cpu()
        for _ in 0..<64 {
            let frame = try await engine.remoteTerminal(sessionID: session.id, realtime: true)
            try expectEqual(frame.question?.options, ["Phone layout", "Desktop layout"])
            try expectEqual(frame.revision, first.revision)
            try expectEqual(frame.streamID, first.streamID)
        }
        let elapsed = cpu() - started
        replace(history + menu.replacingOccurrences(of: "› 1.", with: "  1.")
            .replacingOccurrences(of: "  2. Desktop", with: "› 2. Tablet"))
        try await Task.sleep(for: .milliseconds(200))
        let changed = try await engine.remoteTerminal(sessionID: session.id, realtime: true)
        try expectEqual(changed.question?.selected, 1)
        try expectEqual(changed.question?.options, ["Phone layout", "Tablet layout"])
        try expect(changed.revision != first.revision)
        replace("Working\nesc to interrupt")
        try await Task.sleep(for: .milliseconds(200))
        let cleared = try await engine.remoteTerminal(sessionID: session.id, realtime: true)
        try expect(cleared.question == nil, "A completed menu must not remain attached to later output")
        try expect(engine.snapshot.events.isEmpty && engine.managedPTY.inventory.isEmpty)
        print("METRIC repeated-web-frames 178KB 64-frames \(String(format: "%.2f", elapsed * 1000))ms-CPU")
        try expect(elapsed < 1, "Repeated web frames must not reparse the long menu scrollback")
    }

    func testBackgroundParentLookupAvoidsUnrelatedSessionWalk() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aa-parent-lookup-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let records = ProcessDiscovery.parse("""
        1 0 ?? 1 0 Sat Sep 19 16:00:00 2026 /sbin/launchd
        10 1 ?? 10 0 Sat Sep 19 16:00:01 2026 /System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal
        11 10 ttys032 11 12 Sat Sep 19 16:00:02 2026 /bin/zsh
        12 11 ttys032 12 12 Sat Sep 19 16:38:43 2026 claude
        13 10 ttys033 13 14 Sat Sep 19 16:00:04 2026 /bin/zsh
        14 13 ttys033 14 14 Sat Sep 19 16:00:05 2026 claude
        20 1 ?? 20 0 Sat Sep 19 16:55:10 2026 /Users/test/.local/share/claude/ClaudeCode.app/Contents/MacOS/claude
        21 20 ttys037 21 21 Sat Sep 19 16:55:12 2026 claude
        22 20 ttys038 22 22 Sat Sep 19 16:55:13 2026 claude
        """)
        var sessions = ProcessDiscovery.sessions(records)
        let parentID = sessions.first { $0.pid == 12 }!.id
        let parentIndex = sessions.firstIndex { $0.id == parentID }!
        sessions[parentIndex].channel = .terminalScreen
        let childID = sessions.first { $0.pid == 21 }!.id
        let unrelated = (0..<3_000).map { index in
            AgentSession(id: "process:\(920_000 + index):unrelated", agent: .codex, pid: Int32(920_000 + index),
                started: "unrelated", tty: "/dev/fixture-unrelated-\(index)", cwd: "/tmp", terminal: .terminal)
        }
        let registrations = [
            ClaudeSessionRegistration(processID: parentID, kind: "interactive", parkedJobID: "ca35b27f"),
            ClaudeSessionRegistration(processID: childID, kind: "bg", jobID: "ca35b27f")
        ]
        try expectEqual(ClaudeSessionRegistry.parents(sessions: sessions, records: records, registrations: registrations),
            [childID: parentID], "Fixture relationships resolve before unrelated sessions are added")
        let engine = try ApprovalEngine(paths: AppPaths(directory: root), claudeRegistryReader: { _ in registrations }, processReader: { records })
        defer { engine.stop() }
        engine.updateDiscovery(sessions + unrelated, records: records, claudeRegistrations: registrations)
        try expectEqual(engine.snapshot.sessions.first { $0.id == parentID }?.backgroundChildren.count, 1,
            "Fixture must contain one verified flattened background child")
        let screen = "Do you want to proceed?\n❯ 1. Yes\n  2. No\nEsc to cancel"
        let started = ProcessInfo.processInfo.systemUptime
        // A background child's screen must be ignored because its hook owns replies.
        // Looking up that child's children has no match, so the old implementation
        // necessarily examined every session instead of sometimes finding the parent early.
        for _ in 0..<512 { engine.receiveScreen(sessionID: childID, raw: screen, generation: "fixture", source: ApprovalChannel.terminalScreen) }
        let elapsedMS = (ProcessInfo.processInfo.systemUptime - started) * 1000
        print("METRIC verified-parent-lookup 3000-unrelated 512-frames \(String(format: "%.2f", elapsedMS))ms")
        try expect(elapsedMS < 250, "A frame with one verified background child must not walk unrelated sessions")
        try expectEqual(engine.snapshot.sessions.first { $0.id == parentID }?.backgroundChildren.first { $0.id == childID }?.pendingSummary, nil,
            "A background child's prompt must remain owned by its hook")

        // A persisted relationship table can outlive its processes. With few
        // live sessions and many stale keys, lookup must scan the live inventory.
        let staleRoot = FileManager.default.temporaryDirectory.appendingPathComponent("aa-parent-stale-lookup-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: staleRoot) }
        try FileManager.default.createDirectory(at: staleRoot, withIntermediateDirectories: true)
        let stalePaths = AppPaths(directory: staleRoot)
        let staleStore = try AuditStore(path: stalePaths.database)
        let staleParents = Dictionary(uniqueKeysWithValues: (0..<4_000).map { ("historical-child-\($0)", "historical-parent") })
        try staleStore.set("claudeParents", String(decoding: try JSONEncoder().encode(staleParents), as: UTF8.self))
        let staleEngine = try ApprovalEngine(paths: stalePaths, claudeRegistryReader: { _ in registrations }, processReader: { records })
        defer { staleEngine.stop() }
        staleEngine.updateDiscovery(sessions, records: records, claudeRegistrations: registrations)
        let staleStarted = ProcessInfo.processInfo.systemUptime
        for _ in 0..<512 { staleEngine.receiveScreen(sessionID: childID, raw: screen, generation: "stale-fixture", source: ApprovalChannel.terminalScreen) }
        let staleElapsedMS = (ProcessInfo.processInfo.systemUptime - staleStarted) * 1000
        print("METRIC stale-parent-lookup 4000-stale 512-frames \(String(format: "%.2f", staleElapsedMS))ms")
        try expect(staleElapsedMS < 250, "A large persisted stale map must not dominate lookup with few live sessions")
    }

    func testLargeScreenPollKeepsUIResponsiveAndPublishesTogether() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aa-screen-responsive-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let frames = PollingScreens()
        let adapter = ScreenHostAdapter(screens: { _ in frames.read() }, approve: { _, _, _ in .missingTarget }, reveal: { _ in nil })
        let engine = try ApprovalEngine(paths: AppPaths(directory: root), claudeRegistryReader: { _ in [] }, screenAdapters: [.terminal: adapter])
        defer { engine.stop() }
        let sessions = (0..<24).map {
            AgentSession(id: "process:\(910_000 + $0):large-screen", agent: .codex, pid: Int32(910_000 + $0),
                started: "large-screen", tty: "/dev/fixture-large-\($0)", cwd: root.path, terminal: .terminal)
        }
        engine.updateDiscovery(sessions, records: [])
        frames.set(TerminalSnapshot(screens: sessions.map { TerminalScreen(tty: $0.tty, contents: "Working\nesc to interrupt") }))
        await engine.connectScreenHost(.terminal)
        let raw = String(repeating: "synthetic build output: processed file /fixture/output.swift\n", count: 45_000)
            + "Would you like to run the following command?\n$ pwd\n› 1. Yes\n  2. No\nEsc to cancel"
        frames.set(TerminalSnapshot(screens: sessions.map { TerminalScreen(tty: $0.tty, contents: raw) }))
        var publications = [[SessionPhase]]()
        let subscription = engine.$snapshot.dropFirst().sink { publications.append($0.sessions.map(\.phase)) }
        defer { subscription.cancel() }
        let heartbeat = ScreenHeartbeat()
        let timer = Task { @MainActor in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(10)) } catch { return }
                heartbeat.tick()
            }
        }
        defer { timer.cancel() }
        try await Task.sleep(for: .milliseconds(30)); heartbeat.reset()
        await engine.refreshScreenHost(.terminal)
        let duringAnalysis = heartbeat.ticks
        heartbeat.tick(); timer.cancel()
        try expect(duringAnalysis >= 4, "UI tasks must run while the host analyzes many long screens")
        try expect(heartbeat.largestGap < 0.75, "Long scrollback must not block the UI actor for seconds")
        try expectEqual(publications.count, 1, "Background parsing must keep one coherent host publication")
        try expect(publications[0].allSatisfy { $0 == .approval })
        try expect(engine.snapshot.sessions.allSatisfy { $0.pendingSummary == "Would you like to run the following command?\n$ pwd" && !$0.automatic })
        try expectEqual(engine.snapshot.events.count, 0, "Load observation must not manufacture input")
    }

    func testBackgroundScreenAnalysisPreservesQuestionsErrorsAndSafety() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aa-screen-parsed-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let frames = PollingScreens()
        let adapter = ScreenHostAdapter(screens: { _ in frames.read() }, approve: { _, _, _ in .missingTarget }, reveal: { _ in nil })
        let engine = try ApprovalEngine(paths: AppPaths(directory: root), claudeRegistryReader: { _ in [] }, screenAdapters: [.terminal: adapter])
        defer { engine.stop() }
        let agents: [AgentKind] = [.codex, .claude, .codex, .claude, .codex, .claude, .codex]
        let sessions = agents.enumerated().map { index, agent in
            AgentSession(id: "process:\(920_000 + index):parsed-screen", agent: agent, pid: Int32(920_000 + index),
                started: "parsed-screen", tty: "/dev/fixture-parsed-\(index)", cwd: root.path, terminal: .terminal)
        }
        engine.updateDiscovery(sessions, records: [])
        let history = String(repeating: "synthetic output 한글 🙂 /fixture/source.swift\n", count: 6_000)
        let tails = [
            "Would you like to run the following command?\n$ pwd\n› 1. Yes\n  2. No\nEsc to cancel",
            "Do you want to proceed?\n$ touch ~/Library/LaunchAgents/com.fixture.test.plist\n❯ 1. Yes\n  2. No\nEsc to cancel",
            "Which synthetic test?\n› 1. First\n  2. Second\nEnter to select",
            "Which synthetic test?\n❯ 1. First\n  2. Second\nEnter to select",
            "Original synthetic task\n\n■ stream disconnected before completion: network error\n\n› Ask Codex to do anything\n\n? for shortcuts",
            "Working\nesc to interrupt",
            "› 사용자가 작성한 메모 🙂\n? for shortcuts"
        ]
        for wave in 0..<2 {
            frames.set(TerminalSnapshot(screens: sessions.enumerated().map { index, session in
                TerminalScreen(tty: session.tty, contents: history + "wave \(wave)\n" + tails[index])
            }))
            if wave == 0 { await engine.connectScreenHost(.terminal) } else { await engine.refreshScreenHost(.terminal) }
            let result = Dictionary(uniqueKeysWithValues: engine.snapshot.sessions.map { ($0.id, $0) })
            try expectEqual(result[sessions[0].id]?.phase, .approval)
            try expectEqual(result[sessions[0].id]?.pendingSummary, "Would you like to run the following command?\n$ pwd")
            try expectEqual(result[sessions[1].id]?.phase, .approval)
            try expectNotNil(result[sessions[1].id]?.systemCommandRisk)
            try expectNotNil(result[sessions[1].id]?.systemSafety, "A system mutation remains excluded from ordinary approvals")
            for index in [2, 3] {
                try expectEqual(result[sessions[index].id]?.phase, .input)
                try expect(result[sessions[index].id]?.pendingSummary?.contains("Which synthetic test?") == true)
            }
            try expectEqual(result[sessions[4].id]?.interruption?.kind, .transport)
            try expectEqual(result[sessions[5].id]?.phase, .working)
            try expectEqual(result[sessions[6].id]?.phase, .input, "A user draft must remain user-owned")
            try expect(engine.snapshot.sessions.allSatisfy { !$0.automatic })
            try expect(engine.snapshot.events.allSatisfy { $0.outcome == "시스템 변경 감지 · 자동 승인 제외" })
        }
    }

    func testBackgroundScreenResultsRejectChangedTargetsDisconnectAndCancellation() async throws {
        for action in ["replace", "disconnect", "cancel"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("aa-screen-stale-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let frames = DelayedLargeScreens(); defer { frames.finish() }
            let adapter = ScreenHostAdapter(screens: { frames.read($0) }, approve: { _, _, _ in .missingTarget }, reveal: { _ in nil })
            let engine = try ApprovalEngine(paths: AppPaths(directory: root), claudeRegistryReader: { _ in [] }, screenAdapters: [.terminal: adapter])
            defer { engine.stop() }
            let session = AgentSession(id: "process:42:stale-large", agent: .codex, pid: 42, started: "old",
                tty: "/dev/fixture-stale", cwd: root.path, terminal: .terminal)
            engine.updateDiscovery([session], records: []); await engine.connectScreenHost(.terminal)
            frames.arm(); let pending = Task { await engine.refreshScreenHost(.terminal) }
            let deadline = ProcessInfo.processInfo.systemUptime + 1
            while !frames.waiting, ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(for: .milliseconds(5)) }
            try expect(frames.waiting)
            if action == "replace" {
                var changed = session; changed.pid = 43; changed.started = "new"; changed.tty = "/dev/fixture-replaced"
                engine.updateDiscovery([changed], records: [])
            } else if action == "disconnect" { engine.disconnectScreenHost(.terminal) }
            else { pending.cancel() }
            frames.finish(); await pending.value
            try expect(engine.snapshot.sessions.allSatisfy { $0.systemCommandRisk == nil && $0.systemSafety == nil && $0.pendingSummary == nil }, "A stale or cancelled host result must not create an approval")
            try expect(engine.snapshot.events.isEmpty)
            try expectFalse(engine.snapshot.health.screen(.terminal).connecting)
        }
    }

    func testRepeatedScreensPreserveTimeGenerationAndChangedRequests() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aa-screen-time-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try ApprovalEngine(paths: AppPaths(directory: root), claudeRegistryReader: { _ in [] })
        defer { engine.stop() }
        var session = AgentSession(id: "process:42:screen-time", agent: .codex, pid: 42, started: "screen-time",
            tty: "/dev/fixture-time", cwd: root.path, terminal: .vscode)
        session.channel = .vscodeScreen
        engine.updateDiscovery([session], records: [])
        let idle = "›\n? for shortcuts", now = Date()
        func frame(_ raw: String, seconds: Double, generation: String = "one") {
            engine.receiveScreen(sessionID: session.id, raw: raw, generation: generation, at: now.addingTimeInterval(seconds))
        }
        frame(idle, seconds: 0)
        try expectEqual(engine.snapshot.sessions[0].phase, .unknown)
        frame(idle, seconds: 1)
        try expectEqual(engine.snapshot.sessions[0].phase, .unknown)
        frame(idle, seconds: 2)
        try expectEqual(engine.snapshot.sessions[0].phase, .idle, "Identical text must still advance idle confirmation")
        frame(idle, seconds: 3, generation: "two")
        try expectEqual(engine.snapshot.sessions[0].phase, .unknown, "A new generation must start its own confirmation")
        frame(idle, seconds: 5, generation: "two")
        try expectEqual(engine.snapshot.sessions[0].phase, .idle)
        frame("› 새 지시\n? for shortcuts", seconds: 6)
        try expectEqual(engine.snapshot.sessions[0].phase, .input, "Changed text must be observed immediately")
        frame("Running\nesc to interrupt", seconds: 7)
        try expectEqual(engine.snapshot.sessions[0].phase, .working)
        let question = "Which test?\n› 1. First\n  2. Second\nEnter to select"
        frame(question, seconds: 8)
        let first = engine.snapshot.sessions[0].pendingRequestID
        frame(question, seconds: 9)
        try expectEqual(engine.snapshot.sessions[0].pendingRequestID, first)
        frame(question.replacingOccurrences(of: "Which test?", with: "Which other test?"), seconds: 10)
        try expect(engine.snapshot.sessions[0].pendingRequestID != first, "A new request cannot inherit an old parsed result")
        frame(String(repeating: "synthetic history\n", count: 10_000) + question, seconds: 11)
        try expectEqual(engine.snapshot.sessions[0].phase, .input, "Screens above the cache limit must keep their normal behavior")
        engine.updateDiscovery([], records: [])
        try expectEqual(engine.snapshot.sessions[0].phase, .ended)
        frame(idle, seconds: 12)
        try expectEqual(engine.snapshot.sessions[0].phase, .ended, "An observation cannot revive an ended process")
    }

    func testScreenPollsPublishTogetherAndKeepImmediateUpdates() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aa-screen-batch-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let frames = PollingScreens()
        let adapter = ScreenHostAdapter(screens: { _ in frames.read() }, approve: { _, _, _ in .missingTarget }, reveal: { _ in nil })
        let engine = try ApprovalEngine(paths: AppPaths(directory: root), claudeRegistryReader: { _ in [] }, screenAdapters: [.terminal: adapter])
        defer { engine.stop() }
        let sessions = (0..<16).map { index in
            AgentSession(id: "process:\(900_000 + index):batch", agent: index.isMultiple(of: 2) ? .codex : .claude,
                pid: Int32(900_000 + index), started: "batch", tty: "/dev/fixture-batch-\(index)", cwd: root.path, terminal: .terminal)
        }
        engine.updateDiscovery(sessions, records: [])
        frames.set(TerminalSnapshot(screens: sessions.map { TerminalScreen(tty: $0.tty, contents: "Working\nesc to interrupt") }))
        await engine.connectScreenHost(.terminal)
        var publications: [[SessionPhase]] = []
        let subscription = engine.$snapshot.dropFirst().sink { publications.append($0.sessions.map(\.phase)) }
        defer { subscription.cancel() }
        for _ in 0..<20 { await engine.refreshScreenHost(.terminal) }
        try expectEqual(publications.count, 0, "Healthy unchanged polls must not wake UI or notification subscribers")
        frames.set(TerminalSnapshot(screens: sessions.map { session in
            let heading = session.agent == .codex ? "Would you like to run the following command?" : "Do you want to proceed?"
            return TerminalScreen(tty: session.tty, contents: heading + "\n$ fixture-test\n› 1. Yes\n  2. No\nEsc to cancel")
        }))
        await engine.refreshScreenHost(.terminal)
        try expectEqual(publications.count, 1, "One host result must publish all simultaneous requests together")
        try expect(publications[0].allSatisfy { $0 == .approval })
        try expectEqual(engine.snapshot.attentionCount, 16)
        engine.receiveScreen(sessionID: sessions[0].id, raw: "Which test?\n› 1. First\n  2. Second\nEnter to select", generation: "terminal:" + sessions[0].id)
        try expectEqual(publications.count, 2, "An independent stream update must still publish immediately")
        try expectEqual(engine.snapshot.sessions.first { $0.id == sessions[0].id }?.phase, .input)
        frames.set(TerminalSnapshot())
        await engine.refreshScreenHost(.terminal)
        try expect(engine.snapshot.sessions.allSatisfy { $0.phase == .unknown && $0.channel == .none })
        try expect(publications.allSatisfy { phases in phases.filter { $0 == .unknown }.count == 0 || phases.allSatisfy { $0 == .unknown } }, "Missing tabs must not publish a partially cleared inventory")
        frames.set(TerminalSnapshot(screens: sessions.map { TerminalScreen(tty: $0.tty, contents: "Working\nesc to interrupt") }))
        await engine.connectScreenHost(.terminal)
        try expect(engine.snapshot.sessions.allSatisfy { $0.phase == .working && $0.channel == .terminalScreen })
        try expectFalse(engine.snapshot.health.screen(.terminal).connecting)
        try expectEqual(engine.snapshot.events.count, 0, "Polling must never send an answer")
    }

    func testWorkingDirectoryReadsKeepValidPathsWithDuplicateAndMissingPIDs() throws {
        let pid = getpid()
        let expected = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).resolvingSymlinksInPath().path
        let paths = ProcessDiscovery.workingDirectories(pids: [pid, pid, Int32.max, -1])
        try expectEqual(paths[pid], expected)
        try expectEqual(paths.count, 1, "Missing or invalid processes must not erase a valid cwd or add another process")
        try expectEqual(ProcessDiscovery.cwd(pid: pid), expected)
        try expectEqual(ProcessDiscovery.workingDirectories(pids: []), [:])
    }

    func testUnchangedObservationsDoNotPublishSnapshots() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aa-quiet-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try ApprovalEngine(paths: AppPaths(directory: root), claudeRegistryReader: { _ in [] })
        defer { engine.stop() }
        let session = AgentSession(id: "process:42:quiet", agent: .codex, pid: 42, started: "quiet",
            tty: "/dev/fixture-quiet", cwd: "/tmp", terminal: .vscode)
        engine.updateDiscovery([session], records: [])
        var publications = 0
        let subscription = engine.$snapshot.dropFirst().sink { _ in publications += 1 }
        defer { subscription.cancel() }
        for _ in 0..<100 { engine.refreshNotices() }
        try expectEqual(publications, 0, "Unchanged observations should not invalidate UI or notification subscribers")
        try engine.setCustomization(session.id, value: SessionCustomization(title: "새 이름"))
        try expectEqual(publications, 1, "A changed session must publish immediately")
        try engine.setPaused(true)
        try expect(engine.snapshot.paused)
        try expectEqual(publications, 2, "Pause must still notify subscribers immediately")
    }

    func testQuestionDuplicateIndexPreservesCanonicalAndThreadIdentity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aa-duplicates-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try ApprovalEngine(paths: AppPaths(directory: root), claudeRegistryReader: { _ in [] })
        defer { engine.stop() }
        let session = AgentSession(id: "process:42:duplicates", agent: .codex, pid: 42, started: "duplicates",
            tty: "/dev/fixture-duplicates", cwd: "/tmp", terminal: .vscode)
        engine.updateDiscovery([session], records: [])
        var questions = (0..<100).map {
            QueuedQuestion(id: "unique-\($0)", threadID: "one", title: "질문 \($0)을 진행할까요?", options: ["예", "아니오"])
        }
        questions += [
            .init(id: "first", threadID: "one", title: "계속 진행할까요?", options: ["예", "아니오"]),
            .init(id: "second", threadID: "one", title: "  계속\n진행할까요?  ".decomposedStringWithCanonicalMapping, options: ["예", "아니오"]),
            .init(id: "other-thread", threadID: "two", title: "계속 진행할까요?", options: ["예", "아니오"])
        ]
        engine.updateCodexQuestions([.init(sessionID: session.id, questions: questions, threadID: "one")])
        try expectEqual(Set(engine.snapshot.sessions[0].questions.filter { $0.automation?.phase == .duplicate }.map(\.id)), Set(["first", "second"]))
        try engine.beginQuestionReply(sessionID: session.id, questionID: "second")
        engine.refreshNotices()
        try expectEqual(engine.snapshot.sessions[0].questions.first { $0.id == "second" }?.automation?.phase, .editing)
        questions.removeAll { $0.id == "second" }
        engine.updateCodexQuestions([.init(sessionID: session.id, questions: questions, threadID: "one")])
        try expectFalse(engine.snapshot.sessions[0].questions.contains { $0.automation?.phase == .duplicate }, "Removing a duplicate must invalidate the per-pass index")
    }
}
