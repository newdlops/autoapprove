import Foundation
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
        let result = try CommandRunner.run("/usr/bin/git", ["-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null",
            "-c", "commit.gpgsign=false", "-c", "user.name=AutoApprove Fixture", "-c", "user.email=fixture@example.invalid",
            "-C", (directory ?? root).path] + arguments, environment: environment, inheritEnvironment: false)
        try expectEqual(result.status, 0, result.error)
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension ApprovalTests {
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
