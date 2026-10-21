import Foundation
import Darwin
import AutoApproveCore

private final class GitBranchFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("aa-git-branch-" + UUID().uuidString)
    var repository: URL { root.appendingPathComponent("저장소 with spaces") }
    init() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = try git(["init", "--quiet", "--initial-branch=main", repository.path])
    }
    deinit { try? FileManager.default.removeItem(at: root) }
    @discardableResult func git(_ arguments: [String], at directory: URL? = nil) throws -> String {
        let environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        let operation = arguments.first ?? "unknown"
        let result: CommandResult
        do {
            // Synthetic repository mutations need a bounded setup budget
            // independent of the production read deadline.
            result = try CommandRunner.run("/usr/bin/git", ["-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null",
                "-c", "commit.gpgsign=false", "-c", "user.name=AutoApprove Fixture", "-c", "user.email=fixture@example.invalid",
                "-C", (directory ?? root).path] + arguments, timeout: 30, environment: environment, inheritEnvironment: false)
        } catch {
            throw AppError.message("Git fixture \(operation): \(error.localizedDescription)")
        }
        try expectEqual(result.status, 0, result.error)
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension ApprovalTests {
    func testGitMetadataReadsPreserveSizeBoundariesAndTailBytes() throws {
        let fixture = try GitBranchFixture(), repository = fixture.repository
        let result = try CommandRunner.run("/usr/bin/git", ["-C", repository.path, "symbolic-ref", "HEAD"], timeout: 30)
        let config = repository.appendingPathComponent(".git/config", isDirectory: false)
        var launches = 0
        func read() -> GitBranchState { GitBranchReader.read(directory: repository.path) { _, _ in launches += 1; return result } }
        try expectEqual(read().name, "main")
        for size in [0, 1, 15, 16, 17, 63, 64, 8191, 8192, 8193, 65535, 131072] {
            var contents = Data(repeating: 0x23, count: size) // A valid comment, including without a final newline.
            try contents.write(to: config, options: .atomic)
            let previous = launches
            try expectEqual(read().name, "main"); _ = read()
            try expectEqual(launches, previous + 1, "Exact metadata of size \(size) must be read and then cached")
            if size > 0 {
                contents[size - 1] = 0x0a
                try contents.write(to: config, options: .atomic)
                let beforeTail = launches
                try expectEqual(read().name, "main"); _ = read()
                try expectEqual(launches, beforeTail + 1, "The last byte at size \(size) must participate in the fingerprint")
            }
        }
        try Data(repeating: 0x23, count: 131073).write(to: config, options: .atomic)
        let previous = launches
        _ = read(); _ = read()
        try expectEqual(launches, previous + 2, "Oversized metadata must not enter the cache")
    }

    func testGitMetadataFailedReadsReleaseFileDescriptors() throws {
        let fixture = try GitBranchFixture(), repository = fixture.repository
        let result = try CommandRunner.run("/usr/bin/git", ["-C", repository.path, "symbolic-ref", "HEAD"], timeout: 30)
        let metadata = repository.appendingPathComponent(".git", isDirectory: true)
        let common = metadata.appendingPathComponent("commondir", isDirectory: false)
        let head = metadata.appendingPathComponent("HEAD", isDirectory: false), savedHead = try Data(contentsOf: head)
        var launches = 0
        func read() -> GitBranchState { GitBranchReader.read(directory: repository.path) { _, _ in launches += 1; return result } }
        try expectEqual(read().name, "main"); _ = read(); try expectEqual(launches, 1)
        let before = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, nil, 0)
        try expect(before > 0)
        for file in [common, head] {
            try Data([0xff]).write(to: file, options: .atomic)
            let previous = launches
            for _ in 0..<128 { try expectEqual(read().name, "main") }
            try expectEqual(launches, previous + 128, "Failed metadata must use the current Git executor every time")
            if file == common { try FileManager.default.removeItem(at: common) }
            else { try savedHead.write(to: head, options: .atomic) }
        }
        let after = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, nil, 0)
        try expect(after > 0 && after <= before + Int32(2 * MemoryLayout<proc_fdinfo>.stride),
                   "Repeated failed metadata reads must release their descriptors")
        let previous = launches
        try expectEqual(read().name, "main"); _ = read()
        try expectEqual(launches, previous, "Identical restored metadata can reuse the prior verified branch")
    }

    func testGitMetadataPathHintsPreserveSpecialFileAndSymlinkRevalidation() throws {
        let fixture = try GitBranchFixture(), repository = fixture.repository
        let alias = fixture.root.appendingPathComponent("경로 % # ? e\u{301}", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: repository)
        let result = try CommandRunner.run("/usr/bin/git", ["-C", repository.path, "symbolic-ref", "HEAD"], timeout: 30)
        var launches = 0
        func read() -> GitBranchState { GitBranchReader.read(directory: alias.path) { _, _ in launches += 1; return result } }
        try expectEqual(read().name, "main"); _ = read(); try expectEqual(launches, 1)
        for name in ["HEAD", "config", "config.worktree", "packed-refs"] {
            let file = repository.appendingPathComponent(".git/" + name, isDirectory: false)
            let saved = try? Data(contentsOf: file)
            if saved != nil { try FileManager.default.removeItem(at: file) }
            try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
            let before = launches
            _ = read(); _ = read()
            try expectEqual(launches, before + 2, "A directory named \(name) cannot reuse a verified metadata cache")
            if name == "config" { try expectEqual(GitBranchReader.read(directory: alias.path).kind, .unavailable) }
            try FileManager.default.removeItem(at: file)
            if let saved { try saved.write(to: file, options: .atomic) }
            try expectEqual(read().name, "main")
            let restored = launches; _ = read(); try expectEqual(launches, restored)
        }
        let config = repository.appendingPathComponent(".git/config", isDirectory: false)
        let saved = try Data(contentsOf: config), target = fixture.root.appendingPathComponent("外部 % # config", isDirectory: false)
        try saved.write(to: target)
        try FileManager.default.removeItem(at: config)
        try FileManager.default.createSymbolicLink(at: config, withDestinationURL: target)
        let before = launches
        _ = read(); _ = read(); try expectEqual(launches, before + 2, "No-follow metadata reads must remain misses for symlinks")
        try expectEqual(GitBranchReader.read(directory: alias.path).name, "main", "Git's uncached valid symlink behavior remains available")
        try Data("not a valid config\n".utf8).write(to: target, options: .atomic)
        try expectEqual(GitBranchReader.read(directory: alias.path).kind, .unavailable, "A changed symlink target must expose Git's current error")
        try FileManager.default.removeItem(at: config); try saved.write(to: config, options: .atomic)
        let relative = fixture.root.appendingPathComponent("상대 gitdir % #", isDirectory: true)
        try FileManager.default.createDirectory(at: relative, withIntermediateDirectories: false)
        let marker = relative.appendingPathComponent(".git", isDirectory: false)
        try Data(("gitdir: ../" + repository.lastPathComponent + "/.git\n").utf8).write(to: marker, options: .atomic)
        try expectEqual(GitBranchReader.read(directory: relative.path).name, "main")
        let notDirectory = fixture.root.appendingPathComponent("not-directory", isDirectory: false)
        try Data("file\n".utf8).write(to: notDirectory)
        try Data("gitdir: ../not-directory\n".utf8).write(to: marker, options: .atomic)
        try expect(GitBranchReader.read(directory: relative.path).kind != .branch, "A directory hint cannot make a regular-file gitdir target valid or retain its old branch")
    }

    func testGitBranchMetadataBoundsAndPackedReferenceIdentity() throws {
        let fixture = try GitBranchFixture(), repository = fixture.repository
        let result = try CommandRunner.run("/usr/bin/git", ["-C", repository.path, "symbolic-ref", "HEAD"], timeout: 30)
        let config = repository.appendingPathComponent(".git/config"), savedConfig = try Data(contentsOf: config)
        var launches = 0
        func read() -> GitBranchState { GitBranchReader.read(directory: repository.path) { _, _ in launches += 1; return result } }
        try expectEqual(read().name, "main"); _ = read(); try expectEqual(launches, 1)
        try FileManager.default.removeItem(at: config); try expectEqual(mkfifo(config.path, 0o600), 0)
        let start = ProcessInfo.processInfo.systemUptime
        _ = read(); _ = read(); try expectEqual(launches, 3)
        try expect(ProcessInfo.processInfo.systemUptime - start < 0.25, "A FIFO must never block metadata reads")
        try FileManager.default.removeItem(at: config); try savedConfig.write(to: config)
        _ = read(); _ = read(); try expectEqual(launches, 3, "Restored identical bytes may reuse the last verified branch")
        try Data(repeating: 0x20, count: 131_073).write(to: config)
        _ = read(); _ = read(); try expectEqual(launches, 5, "Oversized metadata must remain a miss")
        try savedConfig.write(to: config)
        let packed = repository.appendingPathComponent(".git/packed-refs"), date = Date(timeIntervalSince1970: 1_000)
        try Data((String(repeating: "a", count: 40) + " refs/heads/other\n").utf8).write(to: packed)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: packed.path)
        _ = read(); _ = read(); try expectEqual(launches, 6)
        let handle = try FileHandle(forWritingTo: packed)
        try handle.write(contentsOf: Data((String(repeating: "b", count: 40) + " refs/heads/other\n").utf8)); try handle.close()
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: packed.path)
        _ = read(); try expectEqual(launches, 7, "Same-size packed refs with restored mtime must still invalidate")
    }
    /// 반복 읽기에서 프로세스를 만들지 않으면서 브랜치·간접 참조 변경은 바로 반영하는지 검증한다.
    func testGitBranchCacheAvoidsProcessLaunchAndTracksReferences() throws {
        let fixture = try GitBranchFixture(), repository = fixture.repository
        try fixture.git(["commit", "--quiet", "--allow-empty", "-m", "fixture"], at: repository)
        var launches = 0
        let execute: ([String], [String: String]) throws -> CommandResult = { arguments, environment in
            launches += 1
            return try CommandRunner.run("/usr/bin/git", arguments, timeout: 30, environment: environment, inheritEnvironment: false)
        }
        try expectEqual(GitBranchReader.read(directory: repository.path, executeGit: execute).name, "main")
        let initial = launches, warmStart = Date()
        for _ in 0..<100 {
            try expectEqual(GitBranchReader.read(directory: repository.path, executeGit: execute).name, "main")
        }
        try expectEqual(launches, initial, "Unchanged branch metadata must not launch another Git process")
        print("Git warm reads: 100 reads, 0 processes, \(Date().timeIntervalSince(warmStart) * 1000) ms")
        try fixture.git(["switch", "--quiet", "-c", "feature/new"], at: repository)
        try expectEqual(GitBranchReader.read(directory: repository.path, executeGit: execute).name, "feature/new")
        try expectEqual(launches, initial + 1)
        try fixture.git(["branch", "feature/alias", "HEAD"], at: repository)
        try fixture.git(["symbolic-ref", "refs/heads/feature/new", "refs/heads/feature/alias"], at: repository)
        try expectEqual(GitBranchReader.read(directory: repository.path, executeGit: execute).name, "feature/alias", "Indirect reference changes must invalidate a cached branch")
        let detached = fixture.root.appendingPathComponent("cache linked worktree")
        try fixture.git(["worktree", "add", "--quiet", "-b", "feature/linked", detached.path, "HEAD"], at: repository)
        try expectEqual(GitBranchReader.read(directory: detached.path, executeGit: execute).name, "feature/linked")
        let linkedInitial = launches
        for _ in 0..<10 { try expectEqual(GitBranchReader.read(directory: detached.path, executeGit: execute).name, "feature/linked") }
        try expectEqual(launches, linkedInitial, "Linked worktree metadata must also avoid repeated Git processes")
        try fixture.git(["switch", "--quiet", "-c", "feature/linked-new"], at: detached)
        try expectEqual(GitBranchReader.read(directory: detached.path, executeGit: execute).name, "feature/linked-new")
    }

    func testGitDetachedHeadCacheAvoidsRepeatedProcessLaunchAndTracksHEADChanges() throws {
        let fixture = try GitBranchFixture(), repository = fixture.repository
        try fixture.git(["commit", "--quiet", "--allow-empty", "-m", "first detached commit"], at: repository)
        try fixture.git(["checkout", "--quiet", "--detach", "HEAD"], at: repository)
        var launches = 0
        let execute: ([String], [String: String]) throws -> CommandResult = { arguments, environment in
            launches += 1
            return try CommandRunner.run("/usr/bin/git", arguments, timeout: 30, environment: environment, inheritEnvironment: false)
        }
        let first = GitBranchReader.read(directory: repository.path, executeGit: execute)
        try expectEqual(first.kind, .detached)
        let initial = launches
        for _ in 0..<20 { try expectEqual(GitBranchReader.read(directory: repository.path, executeGit: execute), first) }
        try expectEqual(launches, initial, "Unchanged detached HEAD metadata must reuse its verified result")
        let warmStart = ProcessInfo.processInfo.systemUptime
        for _ in 0..<100 { _ = GitBranchReader.read(directory: repository.path, executeGit: execute) }
        let warmMilliseconds = (ProcessInfo.processInfo.systemUptime - warmStart) * 1_000
        print("METRIC git-detached-warm 100-reads \(String(format: "%.2f", warmMilliseconds))ms 0-processes")

        let config = repository.appendingPathComponent(".git/config")
        var configData = try Data(contentsOf: config)
        configData.append(Data("\n[autoapprove-fixture]\n\tmarker = true\n".utf8))
        try configData.write(to: config)
        for _ in 0..<20 { try expectEqual(GitBranchReader.read(directory: repository.path, executeGit: execute), first) }
        try expectEqual(launches, initial + 2, "Config changes must revalidate Git's detached result")
        let afterConfig = launches
        for _ in 0..<20 { try expectEqual(GitBranchReader.read(directory: repository.path, executeGit: execute), first) }
        try expectEqual(launches, afterConfig, "Unchanged detached metadata is cached after revalidation")

        try fixture.git(["commit", "--quiet", "--allow-empty", "-m", "next detached commit"], at: repository)
        let expected = try fixture.git(["rev-parse", "--short=8", "HEAD"], at: repository)
        let changed = GitBranchReader.read(directory: repository.path, executeGit: execute)
        try expectEqual(changed, .init(kind: .detached, name: expected), "A detached HEAD change must invalidate the cached result")
        try expectEqual(launches, afterConfig + 2, "A changed detached commit is re-read once")
        _ = GitBranchReader.read(directory: repository.path, executeGit: execute)
        try expectEqual(launches, afterConfig + 2, "The new detached HEAD is cached after verification")
    }

    func testGitDetachedCacheRejectsHEADRace() throws {
        let fixture = try GitBranchFixture(), repository = fixture.repository
        try fixture.git(["commit", "--quiet", "--allow-empty", "-m", "first"] , at: repository)
        let first = try fixture.git(["rev-parse", "HEAD"], at: repository)
        try fixture.git(["commit", "--quiet", "--allow-empty", "-m", "second"], at: repository)
        let second = try fixture.git(["rev-parse", "HEAD"], at: repository)
        try fixture.git(["checkout", "--quiet", "--detach", first], at: repository)
        var launches = 0, injectRace = true
        let execute: ([String], [String: String]) throws -> CommandResult = { arguments, environment in
            launches += 1
            if injectRace && arguments.contains("--short=8") {
                injectRace = false
                try fixture.git(["checkout", "--quiet", "--detach", second], at: repository)
                let result = try CommandRunner.run("/usr/bin/git", arguments, timeout: 30, environment: environment, inheritEnvironment: false)
                try fixture.git(["checkout", "--quiet", "--detach", first], at: repository)
                return result
            }
            return try CommandRunner.run("/usr/bin/git", arguments, timeout: 30, environment: environment, inheritEnvironment: false)
        }
        let raced = GitBranchReader.read(directory: repository.path, executeGit: execute)
        try expectEqual(raced.kind, .detached)
        let corrected = GitBranchReader.read(directory: repository.path, executeGit: execute)
        try expectEqual(corrected.name, String(first.prefix(8)), "A result from an A→B→A race must not be cached under A")
        try expectEqual(launches, 4, "The raced result is retried before it can become a cache hit")
        _ = GitBranchReader.read(directory: repository.path, executeGit: execute)
        try expectEqual(launches, 4, "The verified replacement result is cached")
    }

    func testGitBranchWorktreeAndRefresh() throws {
        let fixture = try GitBranchFixture(), repository = fixture.repository
        try expectEqual(GitBranchReader.read(directory: repository.path), .init(kind: .branch, name: "main"), "An unborn branch still has a name")
        try fixture.git(["commit", "--quiet", "--allow-empty", "-m", "fixture"], at: repository)
        let nested = repository.appendingPathComponent("nested/하위 폴더")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let worktree = fixture.root.appendingPathComponent("linked worktree")
        try fixture.git(["worktree", "add", "--quiet", "-b", "feature/other-worktree", worktree.path, "HEAD"], at: repository)
        let before = try Data(contentsOf: repository.appendingPathComponent(".git/HEAD"))
        try expectEqual(GitBranchReader.read(directory: nested.path).name, "main")
        try expectEqual(GitBranchReader.read(directory: worktree.path).name, "feature/other-worktree")
        try expectEqual(try Data(contentsOf: repository.appendingPathComponent(".git/HEAD")), before, "Reading must leave HEAD unchanged")
        try fixture.git(["switch", "--quiet", "-c", "feature/changed"], at: repository)
        try expectEqual(GitBranchReader.read(directory: nested.path).name, "feature/changed", "No persistent branch cache may hide a switch")
        try expectEqual(GitBranchReader.read(directory: worktree.path).name, "feature/other-worktree")
        try fixture.git(["checkout", "--quiet", "--detach", "HEAD"], at: worktree)
        let detached = GitBranchReader.read(directory: worktree.path)
        try expectEqual(detached.kind, .detached)
        try expectEqual(detached.name, try fixture.git(["rev-parse", "--short=8", "HEAD"], at: worktree))
    }

    func testGitBranchNonRepositoryAndEnvironmentIsolation() throws {
        let fixture = try GitBranchFixture()
        let priorDirectory = ProcessInfo.processInfo.environment["GIT_DIR"]
        let priorWorktree = ProcessInfo.processInfo.environment["GIT_WORK_TREE"]
        setenv("GIT_DIR", fixture.repository.appendingPathComponent(".git").path, 1)
        setenv("GIT_WORK_TREE", fixture.repository.path, 1)
        defer {
            if let priorDirectory { setenv("GIT_DIR", priorDirectory, 1) } else { unsetenv("GIT_DIR") }
            if let priorWorktree { setenv("GIT_WORK_TREE", priorWorktree, 1) } else { unsetenv("GIT_WORK_TREE") }
        }
        try expectEqual(GitBranchReader.read(directory: fixture.root.path).kind, .notRepository, "Inherited Git paths must not identify another repository")
        try expectEqual(GitBranchReader.read(directory: fixture.repository.path).name, "main")
        try expectEqual(GitBranchReader.read(directory: fixture.root.appendingPathComponent("missing").path).kind, .unavailable)
        try expectEqual(GitBranchReader.read(directory: "relative/path").kind, .unavailable)
    }

    func testGitBranchesBindToCurrentSessionDirectory() async throws {
        let fixture = try GitBranchFixture()
        let engine = try ApprovalEngine(paths: AppPaths(directory: fixture.root.appendingPathComponent("app-state")))
        var session = AgentSession(id: "process:42:git-fixture", agent: .codex, pid: 42, started: "git-fixture", tty: "/dev/git-fixture", cwd: fixture.repository.path, terminal: .terminal)
        var duplicate = session; duplicate.id = "process:43:git-fixture"; duplicate.pid = 43
        var ordinary = session; ordinary.id = "shell"; ordinary.agent = .shell
        var ended = session; ended.id = "ended"; ended.phase = .ended
        let updates = await GitBranchReader.collect([session, duplicate, ordinary, ended])
        try expectEqual(Set(updates.map(\.sessionID)), [session.id, duplicate.id])
        try expect(updates.allSatisfy { $0.cwd == fixture.repository.path && $0.state.name == "main" })
        engine.updateDiscovery([session, duplicate], records: [])
        engine.updateGitBranches(updates)
        try expect(engine.snapshot.sessions.allSatisfy { $0.gitBranch?.name == "main" })
        let nonRepository = fixture.root.appendingPathComponent("plain folder")
        try FileManager.default.createDirectory(at: nonRepository, withIntermediateDirectories: true)
        engine.updateDiscovery([session, duplicate], records: [], directories: [session.id: nonRepository.path])
        try expectNil(engine.snapshot.sessions.first { $0.id == session.id }?.gitBranch)
        engine.updateGitBranches(updates)
        try expectNil(engine.snapshot.sessions.first { $0.id == session.id }?.gitBranch)
        session.cwd = nonRepository.path
        engine.updateGitBranches(await GitBranchReader.collect([session]))
        try expectEqual(engine.snapshot.sessions.first { $0.id == session.id }?.gitBranch?.kind, .notRepository)
        try expectEqual(engine.snapshot.sessions.first { $0.id == duplicate.id }?.gitBranch?.name, "main")
        engine.updateDiscovery([], records: [])
        engine.updateGitBranches(updates)
        try expect(engine.snapshot.sessions.allSatisfy { $0.gitBranch == nil }, "Late results must not revive ended sessions")
        let json = try JSONEncoder().encode(session)
        let restored = try JSONDecoder().decode(AgentSession.self, from: json)
        try expect(restored.gitBranch == nil, "Older session payloads without Git metadata remain readable")
    }
}
