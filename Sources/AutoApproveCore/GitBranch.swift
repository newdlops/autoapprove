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
    /// Git resolves nested directories and each linked worktree's own HEAD.
    /// These plumbing reads never scan the worktree, refresh the index or fetch.
    public static func read(directory: String) -> GitBranchState {
        guard directory.hasPrefix("/"), !directory.contains("\0") else {
            return .init(kind: .unavailable, detail: "현재 폴더의 경로를 확인하지 못했습니다.")
        }
        // An app launched from a shell must not inherit a different GIT_DIR,
        // GIT_WORK_TREE, namespace or command-scope Git configuration.
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        environment["LC_ALL"] = "C"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        func git(_ arguments: [String]) throws -> CommandResult {
            try CommandRunner.run("/usr/bin/git", ["-c", "core.fsmonitor=false", "-C", directory] + arguments,
                                  timeout: 1.5, environment: environment, inheritEnvironment: false)
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
                return .init(kind: .branch, name: String(ref.dropFirst("refs/heads/".count)))
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
