import Foundation

public struct GitBranchState: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case branch, detached, notRepository, unavailable }
    public var kind: Kind
    public var name: String?
    public var detail: String?
    public init(kind: Kind, name: String? = nil, detail: String? = nil) {
        self.kind = kind; self.name = name; self.detail = detail
    }
    public var label: String {
        switch kind {
        case .branch: return name ?? "브랜치 확인 불가"
        case .detached: return "detached HEAD · \(name ?? "")"
        case .notRepository: return "Git 저장소 아님"
        case .unavailable: return "브랜치 확인 불가"
        }
    }
}

public struct GitBranchUpdate: Sendable {
    public var sessionID: String
    public var cwd: String
    public var state: GitBranchState
    public init(sessionID: String, cwd: String, state: GitBranchState) {
        self.sessionID = sessionID; self.cwd = cwd; self.state = state
    }
}

public enum GitBranchReader {
    /// macOS 런처의 추가 exec 대기를 피하고, 개발 도구 Git이 없으면 원래 시스템 경로를 쓴다.
    private static let gitExecutable = [
        "/Library/Developer/CommandLineTools/usr/bin/git",
        "/Applications/Xcode.app/Contents/Developer/usr/bin/git",
        "/usr/bin/git"
    ].first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/bin/git"

    /// Git resolves nested directories and each linked worktree's own HEAD.
    /// These plumbing reads never scan the worktree, refresh the index or fetch.
    public static func read(directory: String) -> GitBranchState {
        read(directory: directory) { arguments, environment in
            try CommandRunner.run(gitExecutable, arguments, timeout: 1.5,
                                  environment: environment, inheritEnvironment: false)
        }
    }

    /// 실행기 주입 경계를 공개해 독립 클라이언트와 배포 검사도 동일한 Git 읽기 정책을 사용한다.
    /// - 작은 메타데이터가 같으면 검증된 브랜치를 재사용해 프로세스를 만들지 않는다.
    /// - directory는 작업 폴더이고 executeGit은 격리한 인자·환경을 받는 실제 실행 함수다.
    /// - 반환값은 Git에서 확인한 브랜치·detached 상태 또는 진단 가능한 실패 상태다.
    public static func read(directory: String, executeGit: ([String], [String: String]) throws -> CommandResult) -> GitBranchState {
        guard directory.hasPrefix("/"), !directory.contains("\0") else {
            return .init(kind: .unavailable, detail: "현재 폴더의 경로를 확인하지 못했습니다.")
        }
        let fingerprint = GitBranchCache.fingerprint(directory: directory)
        if let cached = GitBranchCache.value(directory: directory, fingerprint: fingerprint) { return cached }
        // An app launched from a shell must not inherit a different GIT_DIR,
        // GIT_WORK_TREE, namespace or command-scope Git configuration.
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        environment["LC_ALL"] = "C"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        func git(_ arguments: [String]) throws -> CommandResult {
            try executeGit(["-c", "core.fsmonitor=false", "-C", directory] + arguments, environment)
        }
        func failed(_ result: CommandResult) -> GitBranchState {
            let message = result.error.trimmingCharacters(in: .whitespacesAndNewlines)
            if message.hasPrefix("fatal: not a git repository") { return .init(kind: .notRepository) }
            return .init(kind: .unavailable, detail: message.isEmpty ? "Git 브랜치를 읽지 못했습니다. 다음 갱신에서 다시 확인합니다." : String(message.prefix(500)))
        }
        do {
            let branch = try git(["symbolic-ref", "--quiet", "HEAD"])
            let ref = branch.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if branch.status == 0, ref.hasPrefix("refs/heads/"), ref.count > "refs/heads/".count {
                let state = GitBranchState(kind: .branch, name: String(ref.dropFirst("refs/heads/".count)))
                GitBranchCache.store(state, directory: directory, before: fingerprint)
                return state
            }
            guard branch.status == 1 else { return failed(branch) }
            let head = try git(["rev-parse", "--verify", "--short=8", "HEAD"])
            let commit = head.output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard head.status == 0, !commit.isEmpty, commit.allSatisfy(\.isHexDigit) else { return failed(head) }
            return .init(kind: .detached, name: commit)
        } catch { return .init(kind: .unavailable, detail: error.localizedDescription) }
    }

    public static func collect(_ sessions: [AgentSession]) async -> [GitBranchUpdate] {
        let targets = sessions.filter { $0.agent != .shell && $0.phase != .ended && !$0.cwd.isEmpty }
        var directories = Set(targets.map(\.cwd)).sorted().makeIterator()
        let states = await withTaskGroup(of: (String, GitBranchState).self, returning: [String: GitBranchState].self) { group in
            func enqueue(_ directory: String) {
                group.addTask(priority: .utility) {
                    // Process waiting stays off the UI and cooperative executor.
                    await withCheckedContinuation { continuation in
                        DispatchQueue.global(qos: .utility).async {
                            continuation.resume(returning: (directory, read(directory: directory)))
                        }
                    }
                }
            }
            for _ in 0..<4 { if let directory = directories.next() { enqueue(directory) } }
            var results: [String: GitBranchState] = [:]
            for await (directory, state) in group {
                results[directory] = state
                if !Task.isCancelled, let next = directories.next() { enqueue(next) }
            }
            return results
        }
        return targets.compactMap { session in
            states[session.cwd].map { GitBranchUpdate(sessionID: session.id, cwd: session.cwd, state: $0) }
        }
    }
}
