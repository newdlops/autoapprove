import Foundation
import Darwin

public struct CommandResult {
    public var output: String
    public var error: String
    public var status: Int32
}

public enum CommandRunner {
    public static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 8, environment: [String: String] = [:], inheritEnvironment: Bool = true) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = (inheritEnvironment ? ProcessInfo.processInfo.environment : [:]).merging(environment) { _, value in value }
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout; process.standardError = stderr
        try process.run()
        let group = DispatchGroup()
        var out = Data(), err = Data()
        group.enter()
        DispatchQueue.global().async { out = stdout.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter()
        DispatchQueue.global().async { err = stderr.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning { process.terminate(); throw AppError.message("명령 응답 시간이 초과되었습니다: \(URL(fileURLWithPath: executable).lastPathComponent)") }
        group.wait()
        return CommandResult(output: String(decoding: out, as: UTF8.self), error: String(decoding: err, as: UTF8.self), status: process.terminationStatus)
    }
}

public struct ProcessRecord: Equatable {
    public var pid: Int32
    public var parent: Int32
    public var tty: String
    public var processGroup: Int32
    public var foregroundGroup: Int32
    public var started: String
    public var executable: String
    public var agent: AgentKind? {
        let name = URL(fileURLWithPath: executable).lastPathComponent
        if executable.contains("/Applications/ChatGPT.app/") { return nil }
        if name == "codex" { return .codex }
        if name == "claude" || (executable.contains("/claude/versions/") && name.first?.isNumber == true) { return .claude }
        return nil
    }
    public var key: String { "process:\(pid):\(started)" }
    public var isForeground: Bool { processGroup > 0 && processGroup == foregroundGroup }
}

public enum ProcessDiscovery {
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
        // Finder-launched apps inherit the macOS locale; helpers may inherit a different shell locale.
        let result = try CommandRunner.run("/bin/ps", ["-axo", "pid=,ppid=,tty=,pgid=,tpgid=,lstart=,comm="], environment: ["LC_ALL": "C", "LANG": "C"])
        guard result.status == 0 else { throw AppError.message("프로세스 목록을 읽지 못했습니다. \(result.error.trimmingCharacters(in: .whitespacesAndNewlines))") }
        return parse(result.output)
    }
    public static func ancestors(of pid: Int32, records: [ProcessRecord]) -> [ProcessRecord] {
        let byID = Dictionary(records.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        var current = pid, seen: Set<Int32> = [], result: [ProcessRecord] = []
        while let record = byID[current], seen.insert(current).inserted, result.count < 60 {
            result.append(record); current = record.parent
        }
        return result
    }
    public static func sessions(_ records: [ProcessRecord]) -> [AgentSession] {
        return records.compactMap { record in
            guard let agent = record.agent, record.tty != "??", !record.tty.isEmpty else { return nil }
            let parents = ancestors(of: record.parent, records: records)
            guard !parents.contains(where: { $0.agent != nil && $0.tty == record.tty }) else { return nil }
            // A nested PTY may belong to a background agent, not the ancestor's Terminal tab.
            let terminalParents = parents.prefix { $0.tty == "??" || $0.tty == record.tty }
            let backgroundClaude = agent == .claude && terminalParents.contains {
                $0.tty == "??" && ($0.executable.hasSuffix("/ClaudeCode.app/Contents/MacOS/claude") || $0.executable == "claude bg-pty-host")
            }
            let terminal: TerminalKind = backgroundClaude ? .claudeBackground
                : terminalParents.contains(where: { $0.executable.contains("Visual Studio Code.app/") }) ? .vscode
                : terminalParents.contains(where: { $0.executable.hasSuffix("Terminal.app/Contents/MacOS/Terminal") }) ? .terminal : .unknown
            return AgentSession(id: record.key, agent: agent, pid: record.pid, started: record.started, tty: "/dev/\(record.tty)", cwd: "", terminal: terminal)
        }
    }
    public static func cwd(pid: Int32) -> String {
        workingDirectories(pids: [pid])[pid] ?? ""
    }
    public static func workingDirectories(pids: [Int32]) -> [Int32: String] {
        guard !pids.isEmpty, let result = try? CommandRunner.run("/usr/sbin/lsof", ["-a", "-p", pids.map(String.init).joined(separator: ","), "-d", "cwd", "-Fpn"], timeout: 3) else { return [:] }
        var directories: [Int32: String] = [:], current: Int32?
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
