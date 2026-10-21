import Foundation
import AutoApproveCore

private final class GitCollectionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []
    private var active = 0, peak = 0, onMain = false, timedOut = false
    let blocked = DispatchSemaphore(value: 0), progressed = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    let blockAll: Bool
    init(blockAll: Bool = false) { self.blockAll = blockAll }
    func read(_ path: String) -> GitBranchState {
        lock.lock()
        paths.append(path); active += 1; peak = max(peak, active); onMain = onMain || Thread.isMainThread
        let count = paths.count
        lock.unlock()
        defer { lock.lock(); active -= 1; lock.unlock() }
        if count == (blockAll ? 4 : 8) { progressed.signal() }
        if blockAll || path.hasSuffix("/00") {
            blocked.signal()
            if release.wait(timeout: .now() + 5) != .success { lock.lock(); timedOut = true; lock.unlock() }
        }
        return path.hasSuffix("/06") ? .init(kind: .unavailable, detail: "Synthetic failure") : .init(kind: .branch, name: "branch-" + URL(fileURLWithPath: path).lastPathComponent)
    }
    func snapshot() -> (paths: [String], peak: Int, onMain: Bool, timedOut: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (paths, peak, onMain, timedOut)
    }
}

private func waitForGitCollection(_ semaphore: DispatchSemaphore) async -> Bool {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            continuation.resume(returning: semaphore.wait(timeout: .now() + 4) == .success)
        }
    }
}

extension ApprovalTests {
    private func gitCollectionSessions(_ count: Int) -> [AgentSession] {
        (0..<count).map { index in
            var session = AgentSession(id: "fixture-\(index)", agent: .codex, pid: Int32(900001 + index), started: "synthetic-\(index)", tty: "/dev/fixture-\(index)", cwd: String(format: "/fixture/%02d", index), terminal: .terminal)
            session.phase = .idle; return session
        }
    }

    func testGitCollectionKeepsBindingsAndProgressWithBoundedWorkers() async throws {
        let probe = GitCollectionProbe()
        var targets = Array(gitCollectionSessions(16).reversed())
        var duplicate = targets[0]; duplicate.id = "duplicate-cwd"; targets.append(duplicate)
        var shell = targets[0]; shell.id = "shell"; shell.agent = .shell
        var ended = targets[0]; ended.id = "ended"; ended.phase = .ended
        var empty = targets[0]; empty.id = "empty"; empty.cwd = ""
        let inventory = targets + [shell, ended, empty]
        let task = Task { await GitBranchReader.collect(inventory, readDirectory: { probe.read($0) }) }
        let started = await waitForGitCollection(probe.blocked)
        let progressed = await waitForGitCollection(probe.progressed)
        probe.release.signal()
        let updates = await task.value, observed = probe.snapshot()
        try expect(started && progressed, "A slow first directory must allow other queued directories to progress")
        try expectEqual(updates.map(\.sessionID), targets.map(\.id), "Worker completion order must not change session binding or order")
        try expectEqual(updates.map(\.cwd), targets.map(\.cwd))
        try expectEqual(observed.paths.count, 16, "Each distinct eligible directory is read once")
        try expectEqual(Set(observed.paths).count, 16)
        try expect(observed.peak <= 4 && !observed.onMain && !observed.timedOut, "Reads stay bounded and off the UI thread")
        for update in updates {
            if update.cwd.hasSuffix("/06") { try expectEqual(update.state.kind, .unavailable) }
            else { try expectEqual(update.state.name, "branch-" + URL(fileURLWithPath: update.cwd).lastPathComponent) }
        }
    }

    func testGitCollectionCancellationIsLocalAndStopsQueuedReads() async throws {
        let blocked = GitCollectionProbe(blockAll: true), independent = GitCollectionProbe()
        let sessions = gitCollectionSessions(16)
        let task = Task { await GitBranchReader.collect(sessions, readDirectory: { blocked.read($0) }) }
        let fourStarted = await waitForGitCollection(blocked.progressed)
        task.cancel()
        let other = await GitBranchReader.collect(Array(sessions.suffix(3)), readDirectory: { independent.read($0) })
        for _ in 0..<4 { blocked.release.signal() }
        let partial = await task.value, observed = blocked.snapshot()
        try expect(fourStarted, "The test must cancel after the bounded reads are in flight")
        try expectEqual(observed.paths.count, 4, "Cancellation must stop unclaimed directories")
        try expectEqual(partial.count, 4, "Already claimed reads finish and preserve their results")
        try expectEqual(other.map(\.sessionID), Array(sessions.suffix(3)).map(\.id), "Cancellation cannot affect another collect")
        try expect(!observed.timedOut && observed.peak <= 4 && !observed.onMain)
        let cancelled = Task { await GitBranchReader.collect(sessions, readDirectory: { independent.read($0) }) }
        cancelled.cancel()
        let skipped = await cancelled.value
        try expectEqual(skipped.count, 0)
        try expectEqual(independent.snapshot().paths.count, 3, "An already cancelled collect must not start reads")
    }

    func testGitCollectionEmptyTargetsDoNotStartReaders() async throws {
        let probe = GitCollectionProbe()
        var shell = gitCollectionSessions(1)[0]; shell.agent = .shell
        var ended = shell; ended.agent = .codex; ended.phase = .ended
        var empty = ended; empty.phase = .idle; empty.cwd = ""
        let updates = await GitBranchReader.collect([shell, ended, empty], readDirectory: { probe.read($0) })
        try expect(updates.isEmpty && probe.snapshot().paths.isEmpty)
    }
}
