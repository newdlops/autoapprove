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

/// Optional library diagnostics for the bounded, per-collection metadata pool.
/// These counts describe the initial reads, before fresh completion validation.
public struct GitBranchCollectionMetadataMetrics: Sendable {
    public let retainedConfigBytes: Int
    public let retainedConfigs: Int
    public let participants: Int
    public let maximumParticipants: Int
    public let reusedConfigReads: Int
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
        read(directory: directory, metadata: nil, executeGit: executeGit)
    }

    private static func read(directory: String, metadata: GitBranchCache.CollectionMetadata?,
                             executeGit: ([String], [String: String]) throws -> CommandResult) -> GitBranchState {
        guard directory.hasPrefix("/"), !directory.contains("\0") else {
            return .init(kind: .unavailable, detail: "현재 폴더의 경로를 확인하지 못했습니다.")
        }
        let fingerprint = GitBranchCache.fingerprint(directory: directory, metadata: metadata)
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
            let state = GitBranchState(kind: .detached, name: commit)
            GitBranchCache.store(state, directory: directory, before: fingerprint)
            return state
        } catch { return .init(kind: .unavailable, detail: error.localizedDescription) }
    }

    public static func collect(_ sessions: [AgentSession]) async -> [GitBranchUpdate] {
        await collect(sessions, executeGit: { arguments, environment in
            try CommandRunner.run(gitExecutable, arguments, timeout: 1.5,
                                  environment: environment, inheritEnvironment: false)
        })
    }

    /// Shares only bounded common config bytes within this collect. The optional
    /// observer runs off the UI after initial reads and before fresh validation.
    /// A source changed by any observer or concurrent process is re-read normally.
    public static func collect(_ sessions: [AgentSession],
                               executeGit: @escaping @Sendable ([String], [String: String]) throws -> CommandResult,
                               inspectMetadata: (@Sendable (GitBranchCollectionMetadataMetrics) -> Void)? = nil) async -> [GitBranchUpdate] {
        await collect(sessions, shareMetadata: true, inspectMetadata: inspectMetadata) { directory, metadata in
            read(directory: directory, metadata: metadata, executeGit: executeGit)
        }
    }

    /// The synchronous reader runs off the UI/cooperative executor, at most four
    /// directories at once. Cancellation stops claiming new directories; reads
    /// already in flight finish normally. Each collect owns its queue and state.
    public static func collect(_ sessions: [AgentSession], readDirectory: @escaping @Sendable (String) -> GitBranchState) async -> [GitBranchUpdate] {
        await collect(sessions, shareMetadata: false, inspectMetadata: nil) { directory, _ in readDirectory(directory) }
    }

    private static func collect(_ sessions: [AgentSession], shareMetadata: Bool,
                                inspectMetadata: (@Sendable (GitBranchCollectionMetadataMetrics) -> Void)?,
                                readDirectory: @escaping @Sendable (String, GitBranchCache.CollectionMetadata?) -> GitBranchState) async -> [GitBranchUpdate] {
        let targets = sessions.filter { $0.agent != .shell && $0.phase != .ended && !$0.cwd.isEmpty }
        let directories = Set(targets.map(\.cwd)).sorted()
        guard !directories.isEmpty, !Task.isCancelled else { return [] }
        let work = GitBranchCollectionWork(directories)
        let metadata = shareMetadata ? GitBranchCache.collectionMetadata(directories: directories) : nil
        let states: [String: GitBranchState] = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                work.run(readDirectory: { readDirectory($0, metadata) }) {
                    if let inspectMetadata {
                        inspectMetadata(metadata?.metrics() ?? .init(retainedConfigBytes: 0, retainedConfigs: 0,
                            participants: 0, maximumParticipants: 0, reusedConfigReads: 0))
                    }
                    let invalid = metadata?.invalidatedDirectories() ?? []
                    if work.requeue(invalid) {
                        // A changed or unreadable shared config never supplies a
                        // final cached answer. Retry once without any sharing.
                        work.run(readDirectory: { readDirectory($0, nil) }) {
                            continuation.resume(returning: work.results())
                        }
                    } else { continuation.resume(returning: work.results()) }
                }
            }
        } onCancel: {
            work.cancel()
        }
        return targets.compactMap { session in
            states[session.cwd].map { GitBranchUpdate(sessionID: session.id, cwd: session.cwd, state: $0) }
        }
    }
}

/// One collection only: no metadata, input capability or process lifetime is
/// cached here. The lock never spans a reader call or a process wait.
private final class GitBranchCollectionWork: @unchecked Sendable {
    private let lock = NSLock()
    private var directories: [String]
    private var position = 0
    private var cancelled = false
    private var states: [String: GitBranchState] = [:]

    init(_ directories: [String]) {
        self.directories = directories
        states.reserveCapacity(directories.count)
    }
    func next() -> String? {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled, position < directories.count else { return nil }
        defer { position += 1 }
        return directories[position]
    }
    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }
    func store(_ results: [(String, GitBranchState)]) {
        lock.lock(); defer { lock.unlock() }
        for (directory, state) in results { states[directory] = state }
    }
    func results() -> [String: GitBranchState] {
        lock.lock(); defer { lock.unlock() }
        return states
    }
    func requeue(_ invalid: Set<String>) -> Bool {
        guard !invalid.isEmpty else { return false }
        lock.lock(); defer { lock.unlock() }
        for directory in invalid { states.removeValue(forKey: directory) }
        guard !cancelled else { return false }
        directories = invalid.sorted(); position = 0
        return true
    }
    func run(readDirectory: @escaping @Sendable (String) -> GitBranchState, completion: @escaping @Sendable () -> Void) {
        let workers = min(4, directories.count), capacity = (directories.count + workers - 1) / workers
        let group = DispatchGroup()
        for _ in 0..<workers {
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                var results: [(String, GitBranchState)] = []
                results.reserveCapacity(capacity)
                while let directory = self.next() {
                    let state = autoreleasepool { readDirectory(directory) }
                    results.append((directory, state))
                }
                self.store(results); group.leave()
            }
        }
        group.notify(queue: .global(qos: .utility), execute: completion)
    }
}
