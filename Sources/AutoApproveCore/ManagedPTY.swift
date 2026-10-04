import Foundation
import Darwin
private import CPTY

public struct ManagedPTYDescriptor: Codable, Sendable {
    public var ptyID: String
    public var streamID: String
    public var pid: Int32
    public var tty: String
    public var cwd: String
    public var program: String
    public var columns: Int
    public var rows: Int
    public var exitCode: Int?
}

public struct ManagedPTYOutput: Codable, Sendable {
    public var ptyID: String
    public var streamID: String
    public var offset: Int
    public var data: String
    public var reset: Bool
    public var columns: Int
    public var rows: Int
    public var exitCode: Int?
    public var canInput: Bool
}

/// Only app-created masters are retained. Opening a Terminal.app slave does not
/// adopt its process, and this code never opens an existing /dev/tty for input.
public final class ManagedPTY: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private let queue = DispatchQueue(label: "autoapprove.pty.output")
    private var source: DispatchSourceRead?
    private var master: Int32
    private let terminal: OpaquePointer
    private var info: ManagedPTYDescriptor
    private var output = Data()
    private var outputBase = 0
    private var writer: String?
    private var writerUntil = Date.distantPast
    private var writerExpiry: DispatchSourceTimer?
    private var outputObservers: [UUID: @Sendable () -> Void] = [:]
    private var sequences: [String: Int] = [:]
    private var lastUserInput = Date.distantPast
    private var closing = false
    private static let historyLimit = 1_048_576

    public init(cwd: String, program: String = "shell", command: [String]? = nil, columns: Int = 80, rows: Int = 24, environment: [String: String]? = nil) throws {
        try Self.validateSize(columns: columns, rows: rows)
        var directory: ObjCBool = false
        guard cwd.hasPrefix("/"), !cwd.contains("\0"), FileManager.default.fileExists(atPath: cwd, isDirectory: &directory), directory.boolValue else { throw RemoteHTTPError(400, "존재하는 Mac 폴더의 전체 경로를 입력해주세요.") }
        guard ["shell", "codex", "claude"].contains(program) else { throw RemoteHTTPError(400, "지원하지 않는 터미널 프로그램입니다.") }
        guard let vt = ap_vt_new(Int32(rows), Int32(columns)) else { throw AppError.message("터미널 화면을 만들지 못했습니다.") }
        terminal = vt
        let invocation = command ?? (program == "shell" ? [] : [program])
        let arguments = invocation.isEmpty ? ["/bin/zsh", "-l"] : ["/bin/zsh", "-l", "-i", "-c", "cd -- \(Self.quote(cwd)) && exec " + invocation.map(Self.quote).joined(separator: " ")]
        var env = environment ?? ProcessInfo.processInfo.environment
        for key in ["TERM_PROGRAM", "TERM_PROGRAM_VERSION", "ITERM_SESSION_ID", "ORCA_TERMINAL_HANDLE", "__CFBundleIdentifier", "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT"] { env.removeValue(forKey: key) }
        env["TERM"] = "xterm-256color"; env["COLORTERM"] = "truecolor"; env["TERM_PROGRAM"] = "AutoApprovePTY"
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        env["PATH"] = env["PATH"] ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["HOME"] = env["HOME"] ?? NSHomeDirectory()
        let argv = arguments.map { strdup($0) } + [nil]
        let envp = env.sorted { $0.key < $1.key }.map { strdup($0.key + "=" + $0.value) } + [nil]
        defer { for value in argv + envp { free(value) } }
        var pid: Int32 = 0, fd: Int32 = -1, tty = [CChar](repeating: 0, count: 128)
        let result = argv.withUnsafeBufferPointer { a in envp.withUnsafeBufferPointer { e in
            ap_pty_spawn(cwd, a.baseAddress, e.baseAddress, Int32(rows), Int32(columns), &pid, &fd, &tty)
        } }
        guard result == 0 else { ap_vt_free(vt); throw AppError.message("PTY를 열지 못했습니다: \(String(cString: strerror(result)))") }
        master = fd
        info = ManagedPTYDescriptor(ptyID: UUID().uuidString, streamID: UUID().uuidString, pid: pid, tty: String(cString: tty), cwd: cwd, program: program, columns: columns, rows: rows)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        self.source = source
        source.setEventHandler { [weak self] in self?.readAvailable() }; source.resume()
        let expiry = DispatchSource.makeTimerSource(queue: queue)
        writerExpiry = expiry
        expiry.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            if Date() >= self.writerUntil { self.notifyOutputObservers() }
        }
        expiry.schedule(deadline: .distantFuture); expiry.resume()
        // Reaping and termination share the lock. An owned PID cannot be reused
        // between a waitpid result and a delayed termination signal.
        DispatchQueue.global(qos: .utility).async { [self] in
            while true {
                lock.lock()
                var status: Int32 = 0
                let result = waitpid(pid, &status, WNOHANG)
                if result == pid || result < 0 && errno != EINTR {
                    finished(status: result == pid ? ((status & 127) == 0 ? Int((status >> 8) & 255) : 128 + Int(status & 127)) : 255)
                    lock.unlock(); return
                }
                lock.unlock(); usleep(50_000)
            }
        }
    }
    deinit { close(); ap_vt_free(terminal) }
    public var descriptor: ManagedPTYDescriptor { lock.lock(); defer { lock.unlock() }; return info }
    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return !closing && info.exitCode == nil }
    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    static func validateSize(columns: Int, rows: Int) throws {
        guard (20...240).contains(columns), (5...100).contains(rows) else { throw RemoteHTTPError(400, "터미널 크기는 20–240열, 5–100행이어야 합니다.") }
    }
    private func readAvailable() {
        lock.lock(); defer { lock.unlock() }
        guard master >= 0 else { return }
        var bytes = [UInt8](repeating: 0, count: 32_768)
        var consumed = 0
        // Continuous output must yield the lock so the user's Ctrl C can run.
        while consumed < 262_144 {
            let count = Darwin.read(master, &bytes, bytes.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { break }
            consumed += count
            let data = Data(bytes.prefix(count)); output.append(data)
            data.withUnsafeBytes { memory in ap_vt_feed(terminal, memory.baseAddress?.assumingMemoryBound(to: CChar.self), data.count) }
            // One emulator answers DSR/DA/color queries even when no browser is open.
            // Browser xterm query handlers are suppressed to avoid double replies.
            var replies = [CChar](repeating: 0, count: 4096)
            let length = ap_vt_response(terminal, &replies, replies.count)
            if length > 0 { try? writeBytes(Data(bytes: replies, count: length)) }
            if output.count > Self.historyLimit {
                let remove = output.count - Self.historyLimit; output.removeFirst(remove); outputBase += remove
            }
        }
        if consumed > 0 { notifyOutputObservers() }
    }
    private func finished(status: Int) {
        lock.lock(); defer { lock.unlock() }
        readAvailable(); info.exitCode = status
        // A shell may exit before a foreground child. Its controlling PTY and
        // session still identify that group until this master is closed.
        close(); disposeMaster()
        notifyOutputObservers()
    }
    private func disposeMaster() {
        source?.cancel(); source = nil
        writerExpiry?.cancel(); writerExpiry = nil
        if master >= 0 { Darwin.close(master); master = -1 }
    }
    public func close() {
        lock.lock(); defer { lock.unlock() }
        guard master >= 0 else { return }
        closing = true
        // Explicit close/quit must finish even if a job ignores hangup, and must
        // not depend on delayed callbacks after NSApp.terminate. Kill only the
        // groups belonging to this app-created controlling session. The shared
        // reaper lock prevents the owned leader PID being reaped/reused here.
        let foreground = tcgetpgrp(master)
        if ownsForegroundGroup(foreground) { kill(-foreground, SIGKILL) }
        if info.exitCode == nil, getpgid(info.pid) == info.pid { kill(-info.pid, SIGKILL) }
        notifyOutputObservers()
    }
    private func ownsForegroundGroup(_ group: Int32) -> Bool {
        guard group > 0, tcgetpgrp(master) == group else { return false }
        // A PGID names a group, not necessarily a live leader PID. Pipelines
        // retain their group after that first process exits. Inspect only that
        // group and verify a live member in our controlling session before kill.
        let bytes = proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(group), nil, 0)
        guard bytes > 0, bytes <= 1_048_576 else { return false }
        var members = [Int32](repeating: 0, count: Int(bytes) / MemoryLayout<Int32>.size + 16)
        let length = members.withUnsafeMutableBytes { proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(group), $0.baseAddress, Int32($0.count)) }
        guard length > 0 else { return false }
        for pid in members.prefix(Int(length) / MemoryLayout<Int32>.size) where pid > 0 {
            var process = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &process, size) == size,
               process.pbi_status != UInt32(SZOMB), process.pbi_pgid == UInt32(group),
               getsid(pid) == info.pid, getpgid(pid) == group,
               tcgetpgrp(master) == group { return true }
        }
        return false
    }
    func observeOutput(_ observer: @escaping @Sendable () -> Void) -> UUID {
        lock.lock(); defer { lock.unlock() }
        let id = UUID(); outputObservers[id] = observer; return id
    }
    func removeOutputObserver(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }; outputObservers.removeValue(forKey: id)
    }
    private func notifyOutputObservers() {
        // Observers enqueue a coalesced wakeup; none reads or sends while the
        // PTY lock is held. Output itself remains in the bounded history above.
        for observer in outputObservers.values { observer() }
    }
    public func screen() -> String {
        lock.lock(); defer { lock.unlock() }
        guard let value = ap_vt_text(terminal) else { return "" }
        defer { free(value) }; return String(cString: value)
    }
    public func read(after offset: Int?, client: String? = nil) throws -> ManagedPTYOutput {
        lock.lock(); defer { lock.unlock() }
        let end = outputBase + output.count
        guard offset == nil || offset! >= 0 && offset! <= end else { throw RemoteHTTPError(409, "터미널 출력 위치가 바뀌었습니다. 다시 연결해주세요.") }
        let reset = offset == nil || offset! < outputBase
        let data: Data
        let next: Int
        if reset {
            var length = 0
            guard let snapshot = ap_vt_snapshot(terminal, &length) else { throw AppError.message("현재 터미널 화면을 복원하지 못했습니다. 출력이 완료된 뒤 다시 연결해주세요.") }
            defer { free(snapshot) }; data = Data(bytes: snapshot, count: length); next = end
        } else {
            let start = offset! - outputBase; let limit = min(output.count, start + 48_000)
            // Data.removeFirst advances startIndex; offsets are stream-relative.
            data = output.subdata(in: (output.startIndex + start)..<(output.startIndex + limit)); next = outputBase + limit
        }
        return ManagedPTYOutput(ptyID: info.ptyID, streamID: info.streamID, offset: next, data: data.base64EncodedString(), reset: reset, columns: info.columns, rows: info.rows, exitCode: next == end ? info.exitCode : nil, canInput: master >= 0 && !closing && info.exitCode == nil && (writer == client || Date() >= writerUntil))
    }
    private func claim(_ client: String) throws {
        guard UUID(uuidString: client) != nil else { throw RemoteHTTPError(400, "브라우저 연결 ID가 필요합니다.") }
        guard master >= 0, info.exitCode == nil, !closing else { throw RemoteHTTPError(409, "PTY가 종료되었습니다. 마지막 출력은 계속 볼 수 있습니다.") }
        guard writer == client || Date() >= writerUntil else { throw RemoteHTTPError(409, "다른 브라우저에서 입력 중입니다. 잠시 후 화면을 다시 눌러주세요.") }
        writer = client; writerUntil = Date().addingTimeInterval(3)
        writerExpiry?.schedule(deadline: .now() + 3)
        notifyOutputObservers()
    }
    public func input(_ data: Data, streamID: String, client: String, sequence: Int) throws {
        lock.lock(); defer { lock.unlock() }
        guard streamID == info.streamID else { throw RemoteHTTPError(409, "다른 PTY 연결에는 입력을 보낼 수 없습니다.") }
        guard !data.isEmpty, data.count <= 32_000 else { throw RemoteHTTPError(400, "한 번의 터미널 입력은 32,000바이트 이내여야 합니다.") }
        try claim(client)
        guard sequence == (sequences[client] ?? 0) + 1 else { throw RemoteHTTPError(409, "입력 순서가 바뀌었습니다. 다시 보내지 말고 화면을 확인해주세요.") }
        if sequences.count > 32 { sequences = sequences.filter { $0.key == client } }
        // Reserve before writing: a partial/uncertain write can never be replayed.
        sequences[client] = sequence; lastUserInput = Date()
        try writeBytes(data)
    }
    public func resize(columns: Int, rows: Int, streamID: String, client: String) throws {
        try Self.validateSize(columns: columns, rows: rows)
        lock.lock(); defer { lock.unlock() }
        guard streamID == info.streamID else { throw RemoteHTTPError(409, "PTY 연결이 바뀌었습니다.") }
        try claim(client)
        guard info.columns != columns || info.rows != rows else { return }
        let result = ap_pty_resize(master, Int32(rows), Int32(columns))
        guard result == 0 else { throw AppError.message("터미널 크기를 바꾸지 못했습니다: \(String(cString: strerror(result)))") }
        ap_vt_resize(terminal, Int32(rows), Int32(columns)); info.columns = columns; info.rows = rows
        lastUserInput = Date()
        notifyOutputObservers()
    }
    private func writeBytes(_ data: Data) throws {
        guard master >= 0 else { throw RemoteHTTPError(409, "PTY 연결이 종료되었습니다.") }
        var written = 0
        let deadline = Date().addingTimeInterval(1)
        try data.withUnsafeBytes { memory in
            while written < data.count {
                let count = Darwin.write(master, memory.baseAddress!.advanced(by: written), data.count - written)
                if count > 0 { written += count; continue }
                if count < 0 && errno == EINTR { continue }
                if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK), Date() < deadline {
                    var item = pollfd(fd: master, events: Int16(POLLOUT), revents: 0); _ = poll(&item, 1, 20); continue
                }
                throw AppError.message("PTY 입력 결과를 확인하지 못했습니다. 다시 보내지 말고 화면을 확인해주세요.")
            }
        }
    }
    public func approve(expected: String, agent: AgentKind, jobPIDs: [Int32]) throws -> TerminalDelivery {
        lock.lock(); defer { lock.unlock() }
        guard master >= 0, !closing else { return .missingTarget }
        guard Date().timeIntervalSince(lastUserInput) >= 0.8, screen() == expected else { return .screenChanged }
        let group = tcgetpgrp(master)
        guard group > 0, jobPIDs.contains(group) else { return .agentMissing }
        guard let prompt = PromptDetector.detect(expected, agent: agent) else { return .screenChanged }
        try writeBytes(Data((prompt.answer + "\r").utf8)); return .sent
    }
}

public final class ManagedPTYManager: @unchecked Sendable {
    private let lock = NSLock()
    private var terminals: [String: ManagedPTY] = [:]
    private let environment: [String: String]?
    public init(environment: [String: String]? = nil) { self.environment = environment }
    deinit { stop() }
    public var inventory: [ManagedPTYDescriptor] { lock.lock(); defer { lock.unlock() }; return terminals.values.map(\.descriptor).sorted { $0.ptyID < $1.ptyID } }
    public func terminal(_ id: String) throws -> ManagedPTY { lock.lock(); defer { lock.unlock() }; guard let value = terminals[id] else { throw RemoteHTTPError(404, "PTY 터미널을 찾지 못했습니다.") }; return value }
    public func owned(tty: String) -> ManagedPTY? { lock.lock(); defer { lock.unlock() }; return terminals.values.first { $0.descriptor.tty == tty && $0.isRunning } }
    public func create(cwd: String, program: String, command: [String]? = nil, columns: Int, rows: Int) throws -> ManagedPTYDescriptor {
        lock.lock(); defer { lock.unlock() }
        guard terminals.values.filter({ $0.descriptor.exitCode == nil }).count < 8 else { throw RemoteHTTPError(409, "PTY는 Mac 한 대에서 8개까지 열 수 있습니다. 사용하지 않는 터미널을 종료해주세요.") }
        if terminals.count >= 24 { terminals = terminals.filter { $0.value.descriptor.exitCode == nil } }
        let terminal = try ManagedPTY(cwd: cwd, program: program, command: command, columns: columns, rows: rows, environment: environment)
        let info = terminal.descriptor; terminals[info.ptyID] = terminal; return info
    }
    public func stop() { lock.lock(); let values = Array(terminals.values); lock.unlock(); values.forEach { $0.close() } }
    public var adapter: ScreenHostAdapter {
        ScreenHostAdapter(screens: { [self] targets in TerminalSnapshot(screens: targets.compactMap { target in
            guard let terminal = owned(tty: target.tty) else { return nil }
            return TerminalScreen(tty: target.tty, contents: terminal.screen(), title: "PTY · " + terminal.descriptor.program)
        }) }, approve: { [self] target, expected, agent in
            guard let terminal = owned(tty: target.tty) else { return .missingTarget }
            return try terminal.approve(expected: expected, agent: agent, jobPIDs: target.jobPIDs)
        }, reveal: { _ in nil })
    }
}
