import Foundation
import Darwin

public struct CommandResult {
    public var output: String
    public var error: String
    public var status: Int32
}

public enum CommandRunner {
    public static let maximumOutputBytes = 64 * 1024 * 1024
    public static let maximumErrorBytes = 8 * 1024 * 1024
    /// `input` reaches the child on standard input, which keeps text composed; arguments arrive decomposed (NFD).
    /// Complete results are bounded by raw and decoded UTF-8 bytes; overflow is
    /// an error, never a truncated successful response. One deadline covers all pipes.
    public static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 8, environment: [String: String] = [:], inheritEnvironment: Bool = true, input: Data? = nil,
                           outputLimit: Int = maximumOutputBytes, errorLimit: Int = maximumErrorBytes) throws -> CommandResult {
        guard timeout.isFinite, timeout <= Double(Int.max / 1_000_000_000 - 1),
              (0...maximumOutputBytes).contains(outputLimit), (0...maximumErrorBytes).contains(errorLimit) else {
            throw AppError.message("명령 시간 또는 출력 크기 제한이 올바르지 않습니다.")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = (inheritEnvironment ? ProcessInfo.processInfo.environment : [:]).merging(environment) { _, value in value }
        let stdout = Pipe(), stderr = Pipe(), stdin = input.map { _ in Pipe() }
        process.standardOutput = stdout; process.standardError = stderr
        if let stdin { process.standardInput = stdin }
        let completion = CommandPipeCompletion(input:input != nil)
        let io = try CommandPipeIO(stdout:stdout.fileHandleForReading,stderr:stderr.fileHandleForReading,
                                   stdin:stdin?.fileHandleForWriting,data:input,outputLimit:outputLimit,errorLimit:errorLimit,completion:completion)
        defer { io.close() }
        process.terminationHandler = { completion.didExit($0.terminationStatus) }
        try process.run()
        let deadline = DispatchTime.now()+max(0,timeout)
        io.start()
        while true {
            let state = completion.snapshot()
            if let failure = state.failure { try fail(failure) }
            if let status = state.status, state.remaining == 0 {
                let (output,error) = io.take()
                return CommandResult(output:output,error:error,status:status)
            }
            if completion.changed.wait(timeout:deadline) == .timedOut { try fail(.timeout) }
        }
        func fail(_ failure: CommandPipeFailure) throws -> Never {
            completion.fail(failure); io.close()
            // A timed-out helper must not accumulate after ignoring SIGTERM.
            // Only this invocation's owned child is terminated; never its
            // caller, another terminal, or a process group.
            if process.isRunning {
                process.terminate()
                if completion.exited.wait(timeout: .now() + 0.2) == .timedOut, process.isRunning {
                    _ = Darwin.kill(process.processIdentifier, SIGKILL)
                    _ = completion.exited.wait(timeout: .now() + 0.2)
                }
            }
            let name = URL(fileURLWithPath:executable).lastPathComponent
            switch failure {
            case .timeout: throw AppError.message("명령 응답 시간이 초과되었습니다: \(name)")
            case .outputLimit: throw AppError.message("명령 출력이 허용된 크기를 넘었습니다: \(name)")
            case .errorLimit: throw AppError.message("명령 오류 출력이 허용된 크기를 넘었습니다: \(name)")
            case .read: throw AppError.message("명령 파이프를 읽지 못했습니다: \(name)")
            }
        }
    }
}

public struct ProcessRecord: Codable, Equatable, Sendable {
    public var pid: Int32
    public var parent: Int32
    public var tty: String
    public var processGroup: Int32
    public var foregroundGroup: Int32
    public var started: String
    public var executable: String
    public var agent: AgentKind? {
        // ps supplies paths or bare process names. Avoid constructing a file URL
        // for every unrelated process on every discovery/hook. Dot/empty paths
        // retain the old relative-path resolution; never cache across exec/PID reuse.
        let candidate: AgentKind?
        if executable == "codex" { candidate = .codex }
        else if executable == "claude" { candidate = .claude }
        else {
            // Restricted-process fallbacks can contain unrelated bare names.
            guard executable.contains("/") || executable.isEmpty || executable == "." || executable == ".." else { return nil }
            // An agent basename starts with c, or a number for versioned
            // Claude. Reject only conclusive ASCII nonmatches without bridging
            // each ordinary process path to NSString. Dot/empty/foreign names
            // retain Foundation's path and Unicode handling below.
            let unrelated = executable.utf8.withContiguousStorageIfAvailable { bytes in
                var end = bytes.count
                while end > 0 && bytes[end - 1] == 47 { end -= 1 }
                guard end > 0 else { return false }
                var start = end - 1
                while start > 0 && bytes[start - 1] != 47 { start -= 1 }
                let first = bytes[start]
                return first > 0 && first < 128 && first != 99 && first != 46 && !(48...57).contains(first)
            } ?? false
            if unrelated { return nil }
            let component = (executable as NSString).lastPathComponent
            let name = component.isEmpty || component == "." || component == ".."
                ? URL(fileURLWithPath: executable).lastPathComponent : component
            if name == "codex" { candidate = .codex }
            else if name == "claude" || (name.first?.isNumber == true && executable.contains("/claude/versions/")) { candidate = .claude }
            else { return nil }
        }
        return executable.contains("/Applications/ChatGPT.app/") ? nil : candidate
    }
    public var key: String { "process:\(pid):\(started)" }
    public var isForeground: Bool { processGroup > 0 && processGroup == foregroundGroup }
}

public enum ProcessDiscovery {
    public static let workingDirectoryRefreshInterval: TimeInterval = 15

    /// Read new session directories immediately, then avoid repeating kernel
    /// cwd queries on every process-table poll. A directory can change without
    /// changing process identity, so cached values have a short TTL.
    public static func workingDirectoryRefreshIDs(_ identities: [String], lastRead: [String: TimeInterval],
                                                  now: TimeInterval, interval: TimeInterval = workingDirectoryRefreshInterval) -> [String] {
        let ttl = interval.isFinite ? max(0, interval) : workingDirectoryRefreshInterval
        return identities.filter { identity in
            guard let previous = lastRead[identity], previous.isFinite else { return true }
            return !now.isFinite || now - previous >= ttl
        }
    }

    public static func parse(_ output: String) -> [ProcessRecord] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(maxSplits: 10, omittingEmptySubsequences: true, whereSeparator: { $0.isWhitespace })
            guard fields.count == 11, let pid = Int32(fields[0]), let parent = Int32(fields[1]),
                  let group = Int32(fields[3]), let foreground = Int32(fields[4]) else { return nil }
            return ProcessRecord(pid: pid, parent: parent, tty: String(fields[2]), processGroup: group, foregroundGroup: foreground,
                                 started: fields[5...9].joined(separator: " "), executable: String(fields[10]).trimmingCharacters(in: .whitespaces))
        }
    }
    public static func read() throws -> [ProcessRecord] {
        do { return try NativeProcessReader.read() }
        catch is CancellationError { throw CancellationError() }
        catch { return try legacyRead() }
    }
    /// Periodic session discovery needs only CLI candidates and their parent
    /// chain. Keep `read()` complete for callers that inspect arbitrary
    /// processes, but avoid materializing every unrelated process record on
    /// the engine's recurring discovery pass.
    public static func readSessions() throws -> [ProcessRecord] {
        do { return try NativeProcessReader.readSessions() }
        catch is CancellationError { throw CancellationError() }
        catch { return try legacyRead() }
    }
    private static func legacyRead(pid: Int32? = nil) throws -> [ProcessRecord] {
        // Finder-launched apps inherit the macOS locale; helpers may inherit a different shell locale.
        let fields = "pid=,ppid=,tty=,pgid=,tpgid=,lstart=,comm="
        let arguments = pid.map { ["-p", String($0), "-o", fields] } ?? ["-axo", fields]
        let result = try CommandRunner.run("/bin/ps", arguments, environment: ["LC_ALL": "C", "LANG": "C"])
        if pid != nil, result.status == 1 && result.output.isEmpty && result.error.isEmpty { return [] }
        guard result.status == 0 else { throw AppError.message("프로세스 목록을 읽지 못했습니다. \(result.error.trimmingCharacters(in: .whitespacesAndNewlines))") }
        let records = parse(result.output)
        return pid.map { selected in records.filter { $0.pid == selected } } ?? records
    }
    /// Fresh, read-only verification of one original process uses the same
    /// fields and locale as discovery without scanning unrelated processes.
    public static func read(pid: Int32) throws -> [ProcessRecord] {
        guard pid > 0 else { throw AppError.message("올바른 프로세스 ID가 필요합니다.") }
        do { return try NativeProcessReader.read(pid: pid) }
        catch is CancellationError { throw CancellationError() }
        catch { return try legacyRead(pid: pid) }
    }
    public static func ancestors(of pid: Int32, records: [ProcessRecord]) -> [ProcessRecord] {
        let byID = index(records)
        return ancestors(of: pid, byPID: byID)
    }
    /// Build one PID lookup without the intermediate tuple array produced by
    /// `Dictionary(records.map { ... })`. Process snapshots can contain many
    /// unrelated processes, and this path runs during recurring discovery.
    static func index(_ records: [ProcessRecord]) -> [Int32: ProcessRecord] {
        var result: [Int32: ProcessRecord] = [:]
        result.reserveCapacity(records.count)
        for record in records where result[record.pid] == nil { result[record.pid] = record }
        return result
    }
    /// Fresh metadata for a connection's nearest matching enclosing CLI. Read only
    /// its bounded parent chain, then reject an identity/parent/exec/TTY change.
    /// This is attribution, never permission to send input to that process.
    public static func enclosingAgent(of pid: Int32, matching: AgentKind? = nil,
                                      reader: (Int32) throws -> [ProcessRecord] = { try read(pid: $0) }) throws -> ProcessRecord? {
        var current = pid, seen: Set<Int32> = [], chain: [ProcessRecord] = []
        while current > 0, chain.count < 60, seen.insert(current).inserted {
            let values = try reader(current)
            guard values.count == 1, let record = values.first, record.pid == current else { return nil }
            chain.append(record)
            if let kind = record.agent, matching == nil || kind == matching {
                for original in chain.reversed() {
                    let latest = try reader(original.pid)
                    guard latest.count == 1, let value = latest.first,
                          value.pid == original.pid, value.parent == original.parent,
                          value.started == original.started, value.tty == original.tty,
                          value.executable.utf8.elementsEqual(original.executable.utf8) else { return nil }
                }
                return record
            }
            current = record.parent
        }
        return nil
    }
    static func ancestors(of pid: Int32, byPID byID: [Int32: ProcessRecord]) -> [ProcessRecord] {
        var current = pid, seen: Set<Int32> = [], result: [ProcessRecord] = []
        while let record = byID[current], seen.insert(current).inserted, result.count < 60 {
            result.append(record); current = record.parent
        }
        return result
    }
    static let environmentCache = ProcessEnvironmentCache()
    /// `environment` replaces the live, cached launch-variable reader (tests pass fixtures).
    public static func sessions(_ records: [ProcessRecord], environment: ((ProcessRecord) -> [String: String]?)? = nil) -> [AgentSession] {
        var byID: [Int32: ProcessRecord] = [:]
        byID.reserveCapacity(records.count)
        // Resolve executable identity once per process snapshot. Ancestor
        // checks below revisit the same records for sibling CLI sessions.
        var agentByPID: [Int32: AgentKind] = [:]
        agentByPID.reserveCapacity(min(records.count, 32))
        for record in records {
            if byID[record.pid] == nil { byID[record.pid] = record }
            if let agent = record.agent { agentByPID[record.pid] = agent }
        }
        let found: [AgentSession] = records.compactMap { record in
            guard let agent = agentByPID[record.pid], record.tty != "??", !record.tty.isEmpty else { return nil }
            let parents = ancestors(of: record.parent, byPID: byID)
            guard !parents.contains(where: { agentByPID[$0.pid] != nil && $0.tty == record.tty }) else { return nil }
            // A nested PTY may belong to a background agent, not the ancestor's Terminal tab.
            let terminalParents = parents.prefix { $0.tty == "??" || $0.tty == record.tty }
            let backgroundClaude = agent == .claude && terminalParents.contains {
                $0.tty == "??" && ($0.executable.hasSuffix("/ClaudeCode.app/Contents/MacOS/claude") || $0.executable == "claude bg-pty-host")
            }
            var session = AgentSession(id: record.key, agent: agent, pid: record.pid, started: record.started, tty: "/dev/\(record.tty)", cwd: "", terminal: .claudeBackground)
            guard !backgroundClaude else { return session }
            let host = TerminalHost.classify(record: record, parents: parents, environment: {
                environment.map { $0(record) ?? [:] } ?? environmentCache.environment(record, reader: ProcessEnvironment.read)
            })
            session.terminal = host.kind; session.hostName = host.name; session.hostBundleID = host.bundleID; session.orcaHandle = host.orcaHandle
            session.tmuxHandle = host.tmuxHandle
            return session
        }
        if environment == nil { environmentCache.retain(Set(found.lazy.map(\.id))) }
        return found
    }
    public static func cwd(pid: Int32) -> String {
        workingDirectories(pids: [pid])[pid] ?? ""
    }
    public static func workingDirectories(pids: [Int32]) -> [Int32: String] {
        var directories: [Int32: String] = [:], missing: [Int32] = []
        for pid in Set(pids) where pid > 0 {
            var info = proc_vnodepathinfo()
            let size = Int32(MemoryLayout.size(ofValue: info))
            let path: String? = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size
                ? withUnsafeBytes(of: info.pvi_cdir.vip_path) { bytes in
                    guard let end = bytes.firstIndex(of: 0), end > 0 else { return nil }
                    let value = String(decoding: bytes[..<end], as: UTF8.self)
                    return value.hasPrefix("/") ? value : nil
                } : nil
            if let path { directories[pid] = path } else { missing.append(pid) }
        }
        // Read the current kernel cwd every poll; never cache a path across chdir or PID reuse.
        // Keep the existing reader for processes whose path libproc cannot provide.
        guard !missing.isEmpty, let result = try? CommandRunner.run("/usr/sbin/lsof", ["-a", "-p", missing.map(String.init).joined(separator: ","), "-d", "cwd", "-Fpn"], timeout: 3) else { return directories }
        var current: Int32?
        for line in result.output.split(separator: "\n") {
            if line.hasPrefix("p") { current = Int32(line.dropFirst()) }
            else if line.hasPrefix("n/"), let pid = current { directories[pid] = String(line.dropFirst()) }
        }
        return directories
    }
    public static func terminalSize(tty: String) -> (columns: Int, rows: Int)? {
        guard tty.hasPrefix("/dev/tty"), !tty.contains("..") else { return nil }
        let fd = Darwin.open(tty, O_RDONLY | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { return nil }; defer { Darwin.close(fd) }
        var size = winsize()
        guard ioctl(fd, TIOCGWINSZ, &size) == 0, size.ws_col > 0, size.ws_row > 0 else { return nil }
        return (Int(size.ws_col), Int(size.ws_row))
    }
}
