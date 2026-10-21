import Foundation
import Darwin
import AutoApproveCore

private final class GitMetadataGate: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0), lock = NSLock()
    private var remaining = 4
    func wait() {
        lock.lock()
        guard remaining > 0 else { lock.unlock(); return }
        remaining -= 1
        let last = remaining == 0
        lock.unlock()
        if last { entered.signal() }
        _ = release.wait(timeout: .now() + 5)
    }
    func releaseAll() { for _ in 0..<4 { release.signal() } }
}

private final class GitMetadataFixture: @unchecked Sendable {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("aa-git-metadata-" + UUID().uuidString, isDirectory: true)
    let seed: CommandResult
    var sessions: [AgentSession] = []
    var configs: [URL] = [], heads: [String: URL] = [:], privateConfigs: [String: URL] = [:]
    private let lock = NSLock()
    private var calls: [String: Int] = [:]
    private var observed: GitBranchCollectionMetadataMetrics?
    private var once: (String, () -> Void)?
    private var gate: GitMetadataGate?
    var executor: @Sendable ([String], [String: String]) throws -> CommandResult { { try self.execute($0, $1) } }
    var observer: @Sendable (GitBranchCollectionMetadataMetrics) -> Void { { self.inspect($0) } }

    init(groups: Int = 1, members: Int = 18, size: Int = 1024) throws {
        seed = try CommandRunner.run("/usr/bin/git", ["--version"], timeout: 30)
        try expectEqual(seed.status, 0)
        for group in 0..<groups {
            let common = root.appendingPathComponent("common-\(group)", isDirectory: true)
            try FileManager.default.createDirectory(at: common.appendingPathComponent("refs/heads", isDirectory: true), withIntermediateDirectories: true)
            let config = common.appendingPathComponent("config", isDirectory: false)
            try Data(repeating: 0x23, count: size).write(to: config)
            configs.append(config)
            for member in 0..<members {
                let number = sessions.count
                let directory = root.appendingPathComponent(String(format: "worktree-%04d", number), isDirectory: true)
                let admin = common.appendingPathComponent("worktrees/\(member)", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: admin, withIntermediateDirectories: true)
                try Data("gitdir: \(admin.path)\n".utf8).write(to: directory.appendingPathComponent(".git", isDirectory: false))
                try Data("../..\n".utf8).write(to: admin.appendingPathComponent("commondir", isDirectory: false))
                let head = admin.appendingPathComponent("HEAD", isDirectory: false)
                try Data("ref: refs/heads/main\n".utf8).write(to: head)
                heads[directory.path] = head
                privateConfigs[directory.path] = admin.appendingPathComponent("config.worktree", isDirectory: false)
                var session = AgentSession(id: "metadata-\(number)", agent: .codex, pid: Int32(900001 + number),
                    started: "synthetic-\(number)", tty: "/dev/fixture-\(number)", cwd: directory.path, terminal: .terminal)
                session.phase = .idle; sessions.append(session)
            }
        }
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    func execute(_ arguments: [String], _ environment: [String: String]) throws -> CommandResult {
        guard let position = arguments.firstIndex(of: "-C"), arguments.indices.contains(position + 1) else { throw AppError.message("Missing fixture cwd") }
        let directory = arguments[position + 1]
        lock.lock()
        calls[directory, default: 0] += 1
        let action = once?.0 == directory ? once?.1 : nil
        let barrier = gate
        if action != nil { once = nil }
        lock.unlock()
        action?()
        barrier?.wait()
        var result = seed
        result.status = 0; result.error = ""
        let head = try String(contentsOf: heads[directory]!, encoding: .utf8)
        result.output = String(head.dropFirst("ref: ".count))
        return result
    }
    func warm(_ sessions: [AgentSession]? = nil) {
        // A second pass also repopulates this fixture after the global bounded
        // cache discarded unrelated entries while warming the first pass.
        for _ in 0..<2 { for session in sessions ?? self.sessions {
            _ = GitBranchReader.read(directory: session.cwd, executeGit: execute)
        } }
        clearCalls()
    }
    func clearCalls() { lock.lock(); calls.removeAll(); lock.unlock() }
    func callCounts() -> [String: Int] { lock.lock(); defer { lock.unlock() }; return calls }
    func inspect(_ value: GitBranchCollectionMetadataMetrics) { lock.lock(); observed = value; lock.unlock() }
    func metrics() -> GitBranchCollectionMetadataMetrics? { lock.lock(); defer { lock.unlock() }; return observed }
    func onNextExecution(_ path: String, _ action: @escaping () -> Void) { lock.lock(); once = (path, action); lock.unlock() }
    func prepareReadGate() throws -> GitMetadataGate {
        // The first four readers finish their config snapshot before waiting in
        // the injected executor. This makes pool-capacity checks independent of
        // whether another worker happened to read during the initial load.
        for session in sessions.prefix(4) {
            try Data(("# gate " + UUID().uuidString).utf8).write(to: privateConfigs[session.cwd]!, options: .atomic)
        }
        let value = GitMetadataGate()
        lock.lock(); gate = value; lock.unlock()
        return value
    }
}

private func waitForGitMetadata(_ semaphore: DispatchSemaphore) async -> Bool {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            continuation.resume(returning: semaphore.wait(timeout: .now() + 5) == .success)
        }
    }
}

private func releaseGitMetadataGate(_ gate: GitMetadataGate, fixture: GitMetadataFixture) async throws {
    let ready = await waitForGitMetadata(gate.entered)
    fixture.clearCalls(); gate.releaseAll()
    try expect(ready, "All initial readers must finish their fingerprints before the pool is exercised")
}

extension ApprovalTests {
    func testGitCollectionSharedConfigIsValidatedAfterInspection() async throws {
        let fixture = try GitMetadataFixture(), changed = fixture.configs[0]
        fixture.warm()
        let gate = try fixture.prepareReadGate()
        let task = Task { await GitBranchReader.collect(fixture.sessions, executeGit: fixture.executor) { metrics in
            fixture.inspect(metrics)
            // Same size and restored mtime must not hide a completion-time edit.
            let attributes = try? FileManager.default.attributesOfItem(atPath: changed.path)
            try? Data(repeating: 0x20, count: 1024).write(to: changed)
            if let date = attributes?[.modificationDate] { try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: changed.path) }
        } }
        try await releaseGitMetadataGate(gate, fixture: fixture)
        let updates = await task.value
        guard let metrics = fixture.metrics() else { throw AppError.message("Missing collection diagnostics") }
        try expectEqual(updates.map(\.sessionID), fixture.sessions.map(\.id))
        try expect(metrics.reusedConfigReads > 0 && metrics.participants > 1)
        try expectEqual(fixture.callCounts().values.reduce(0, +), metrics.participants,
                        "Every directory using the shared snapshot must be freshly retried after the edit")
        let next = await GitBranchReader.collect(fixture.sessions, executeGit: fixture.executor)
        try expectEqual(next.count, fixture.sessions.count, "A later collect must not retain the earlier snapshot")
        for session in fixture.sessions {
            try expectEqual(GitBranchReader.read(directory: session.cwd, executeGit: fixture.execute).name, "main")
        }
    }

    func testGitCollectionKeepsWorktreeMetadataFresh() async throws {
        let fixture = try GitMetadataFixture()
        fixture.warm()
        let changed = fixture.sessions[0], configured = fixture.sessions[1]
        try Data("ref: refs/heads/changed\n".utf8).write(to: fixture.heads[changed.cwd]!, options: .atomic)
        try Data("# private worktree change\n".utf8).write(to: fixture.privateConfigs[configured.cwd]!, options: .atomic)
        let updates = await GitBranchReader.collect(fixture.sessions, executeGit: fixture.executor, inspectMetadata: fixture.observer)
        try expectEqual(updates[0].state.name, "changed")
        try expectEqual(updates[1].state.name, "main")
        try expectEqual(fixture.callCounts(), [changed.cwd: 1, configured.cwd: 1], "A shared common config cannot hide private HEAD/config changes")
        try expect((fixture.metrics()?.retainedConfigs ?? 0) > 0)
    }

    func testGitCollectionSpecialSharedConfigLeavesRemainUncached() async throws {
        for kind in ["symlink", "fifo", "oversized", "directory"] {
            let fixture = try GitMetadataFixture(members: 9)
            fixture.warm()
            let config = fixture.configs[0]
            try FileManager.default.removeItem(at: config)
            switch kind {
            case "symlink":
                let target = fixture.root.appendingPathComponent("config-target", isDirectory: false)
                try Data("# symlink target\n".utf8).write(to: target)
                try FileManager.default.createSymbolicLink(at: config, withDestinationURL: target)
            case "fifo": try expectEqual(mkfifo(config.path, 0o600), 0)
            case "oversized": try Data(repeating: 0x23, count: 131073).write(to: config)
            default: try FileManager.default.createDirectory(at: config, withIntermediateDirectories: false)
            }
            let updates = await GitBranchReader.collect(fixture.sessions, executeGit: fixture.executor, inspectMetadata: fixture.observer)
            try expectEqual(updates.count, fixture.sessions.count)
            try expectEqual(fixture.callCounts().values.reduce(0, +), fixture.sessions.count, "\(kind) must bypass cached answers")
            try expectEqual(fixture.metrics()?.retainedConfigs, 0)
            try expectEqual(fixture.metrics()?.reusedConfigReads, 0)
            let path = fixture.sessions[0].cwd
            _ = GitBranchReader.read(directory: path, executeGit: fixture.execute)
            try expectEqual(fixture.callCounts()[path], 2, "Failed \(kind) metadata cannot be stored by the Git recheck")
        }
    }

    func testGitCollectionMissingSharedConfigAndBoundedPool() async throws {
        let missing = try GitMetadataFixture(members: 18)
        try FileManager.default.removeItem(at: missing.configs[0]); missing.warm()
        let updates = await GitBranchReader.collect(missing.sessions, executeGit: missing.executor, inspectMetadata: missing.observer)
        try expectEqual(updates.count, missing.sessions.count)
        try expect(missing.callCounts().isEmpty, "Absent optional config is distinct from a failed read")
        try expectEqual(missing.metrics()?.retainedConfigBytes, 0)
        try expect((missing.metrics()?.reusedConfigReads ?? 0) > 0)

        for (groups, members, bytes) in [(3, 3, 131072), (65, 3, 128), (1, 300, 1024)] {
            let fixture = try GitMetadataFixture(groups: groups, members: members, size: bytes)
            fixture.warm(members > 256 ? Array(fixture.sessions.prefix(16)) : nil)
            let collected: [GitBranchUpdate]
            if members > 256 {
                let gate = try fixture.prepareReadGate()
                let task = Task { await GitBranchReader.collect(fixture.sessions, executeGit: fixture.executor, inspectMetadata: fixture.observer) }
                try await releaseGitMetadataGate(gate, fixture: fixture)
                collected = await task.value
            } else { collected = await GitBranchReader.collect(fixture.sessions, executeGit: fixture.executor, inspectMetadata: fixture.observer) }
            guard let metrics = fixture.metrics() else { throw AppError.message("Missing bounded pool diagnostics") }
            try expectEqual(collected.map(\.sessionID), fixture.sessions.map(\.id))
            try expect(metrics.retainedConfigBytes <= 262144 && metrics.retainedConfigs <= 64 && metrics.maximumParticipants <= 256)
            try expect(metrics.retainedConfigs > 0 && metrics.participants >= metrics.retainedConfigs)
            if groups == 3 { try expectEqual(metrics.retainedConfigs, 2); try expectEqual(metrics.retainedConfigBytes, 262144) }
            if groups == 65 { try expectEqual(metrics.retainedConfigs, 64) }
            if members == 300 { try expectEqual(metrics.maximumParticipants, 256) }
        }
    }

    func testGitCollectionCancellationDropsChangedSnapshotsWithoutRetry() async throws {
        let fixture = try GitMetadataFixture(), entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        fixture.warm()
        let gate = try fixture.prepareReadGate()
        let task = Task {
            await GitBranchReader.collect(fixture.sessions, executeGit: fixture.executor) { metrics in
                fixture.inspect(metrics); entered.signal(); _ = release.wait(timeout: .now() + 5)
            }
        }
        try await releaseGitMetadataGate(gate, fixture: fixture)
        let waiting = await waitForGitMetadata(entered)
        task.cancel()
        try Data(repeating: 0x20, count: 1024).write(to: fixture.configs[0], options: .atomic)
        release.signal()
        let updates = await task.value
        try expect(waiting)
        guard let metrics = fixture.metrics() else { throw AppError.message("Missing cancellation diagnostics") }
        try expect(metrics.reusedConfigReads > 0)
        try expectEqual(updates.count, fixture.sessions.count - metrics.participants,
                        "Cancelled collects must drop affected shared answers without starting replacement reads")
        try expect(fixture.callCounts().isEmpty)
        let other = await GitBranchReader.collect(fixture.sessions, executeGit: fixture.executor)
        try expectEqual(other.count, fixture.sessions.count, "Cancelled metadata is local to its collect")
    }

    func testGitCollectionPostGitStoreRecheckIsIndependentOfSnapshot() async throws {
        let fixture = try GitMetadataFixture(), entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let cold = fixture.sessions[0]
        fixture.warm(Array(fixture.sessions.dropFirst()))
        fixture.onNextExecution(cold.cwd) {
            try? Data(repeating: 0x20, count: 1024).write(to: fixture.configs[0], options: .atomic)
        }
        let task = Task {
            await GitBranchReader.collect(fixture.sessions, executeGit: fixture.executor) { _ in
                entered.signal(); _ = release.wait(timeout: .now() + 5)
            }
        }
        let waiting = await waitForGitMetadata(entered)
        task.cancel(); release.signal(); _ = await task.value
        try expect(waiting)
        try expectEqual(fixture.callCounts()[cold.cwd], 1)
        _ = GitBranchReader.read(directory: cold.cwd, executeGit: fixture.execute)
        try expectEqual(fixture.callCounts()[cold.cwd], 2, "A config changed during Git execution must fail the independent original store recheck")
    }
}
