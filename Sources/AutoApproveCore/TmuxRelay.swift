import Foundation
import Darwin
import TerminalInputSupport

/// A pane ID is never reused during a server's lifetime. The server's launch
/// identity also prevents a replacement server at the same socket being shared.
public struct TmuxPaneHandle: Codable, Equatable, Sendable {
    public var socket: String
    public var serverPID: Int32
    public var serverStarted: String
    public var pane: String
    public var encoded: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return String(decoding: try! encoder.encode(self), as: UTF8.self)
    }
    public static func isServer(_ executable: String) -> Bool {
        URL(fileURLWithPath: executable).lastPathComponent == "tmux" || executable.hasPrefix("tmux: server")
    }
    public static func launch(_ environment: [String: String], server: ProcessRecord) -> Self? {
        guard let value = environment["TMUX"], let pane = environment["TMUX_PANE"] else { return nil }
        let fields = value.split(separator: ",", omittingEmptySubsequences: false)
        guard fields.count >= 3, let pid = Int32(fields[fields.count - 2]), pid == server.pid else { return nil }
        let socket = fields.dropLast(2).joined(separator: ",")
        let result = Self(socket: socket, serverPID: pid, serverStarted: server.started, pane: pane)
        return result.valid ? result : nil
    }
    public init?(encoded: String) {
        guard encoded.utf8.count <= 4096, let value = try? JSONDecoder().decode(Self.self, from: Data(encoded.utf8)), value.valid else { return nil }
        self = value
    }
    public init(socket: String, serverPID: Int32, serverStarted: String, pane: String) {
        self.socket = socket; self.serverPID = serverPID; self.serverStarted = serverStarted; self.pane = pane
    }
    private var valid: Bool {
        socket.hasPrefix("/") && socket.utf8.count < 104 && !socket.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 })
            && serverPID > 0 && ProcessEnvironment.startDate(serverStarted) != nil
            && Self.identifier(pane, prefix: "%")
    }
    static func identifier(_ value: String, prefix: Character) -> Bool {
        value.first == prefix && (2...20).contains(value.utf8.count) && value.dropFirst().allSatisfy { $0.isASCII && $0.isNumber }
    }
    func validate() throws {
        var info = proc_bsdinfo(), socketInfo = stat()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard valid, lstat(socket, &socketInfo) == 0,
              socketInfo.st_mode & S_IFMT == S_IFSOCK, socketInfo.st_uid == getuid(),
              socketInfo.st_mode & 0o022 == 0,
              proc_pidinfo(serverPID, PROC_PIDTBSDINFO, 0, &info, size) == size,
              info.pbi_uid == getuid(), info.pbi_ruid == getuid(),
              let started = ProcessEnvironment.startDate(serverStarted),
              abs(Double(info.pbi_start_tvsec) - started.timeIntervalSince1970) < 2 else {
            throw AppError.message("원래 tmux 서버가 종료되거나 소켓 소유자가 바뀌었습니다. Mac에서 원래 세션을 확인해주세요.")
        }
    }
}

/// Uses only tmux's public commands as the signed-in user. The ignore-size
/// control client reads snapshots and notifications; only an explicit input
/// or enabled approval writes to the selected pane. It never creates a PTY.
public final class TmuxRelay: @unchecked Sendable {
    public static let shared = TmuxRelay()
    private let lock = NSLock()
    private var links: [String: TmuxControlConnection] = [:]
    private var cached: [String: (UInt64, Date, TerminalScreen)] = [:]
    public init() {}
    public static var executable: String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [home + "/.local/bin/tmux", "/opt/homebrew/bin/tmux", "/usr/local/bin/tmux"]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/tmux" }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    public static var startCommand: String {
        let command = executable.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" } ?? "tmux"
        return command + " new-session -A -s autoapprove"
    }
    public var adapter: ScreenHostAdapter {
        ScreenHostAdapter(screens: { [self] targets in
            guard Self.executable != nil else { throw AppError.message("이 Mac에 tmux를 설치해주세요. 휴대폰에는 설치하지 않습니다.") }
            var result = TerminalSnapshot()
            for target in targets {
                do { result.screens.append(try screen(target)) }
                catch { result.failures.append(TerminalReadFailure(tty: target.tty, message: error.localizedDescription)) }
            }
            return result
        }, approve: { [self] target, expected, agent in
            guard let dialog = try AutomationScript.dialogData(tty: target.tty, expectedScreen: expected, agent: agent)["dialog"] as? String else { return .screenChanged }
            let current = try screen(target, fresh: true).contents
            guard OrcaAdapter.activeDialog(current, dialog: dialog, agent: agent) == OrcaAdapter.normalize(dialog) else { return .screenChanged }
            return try send(target, agent: agent, bytes: Data("1\r".utf8))
        }, reveal: { _ in nil }, input: { [self] target, expected, agent, input in
            try input.validate()
            if !input.isRelay, OrcaAdapter.normalize(try screen(target, fresh: true).contents) != OrcaAdapter.normalize(expected) { return .screenChanged }
            return try send(target, agent: agent, bytes: Data(input.bytes.utf8))
        })
    }
    private static let metadataFormat = ["pid", "session_id", "pane_id", "pane_pid", "pane_tty", "pane_width", "pane_height", "cursor_x", "cursor_y", "cursor_flag", "cursor_shape", "cursor_blinking", "pane_in_mode", "synchronize-panes", "pane_input_off"].map { "#{\($0)}" }.joined(separator: "|")
    private struct Pane {
        var session: String; var pid: Int32; var columns: Int; var rows: Int
        var x: Int; var y: Int; var visible: Bool; var shape: String; var blink: Bool
        var inMode: Bool; var synchronized: Bool; var inputOff: Bool
        init(_ text: String, handle: TmuxPaneHandle, tty: String) throws {
            let fields = text.trimmingCharacters(in: .newlines).components(separatedBy: "|")
            guard fields.count == 15, Int32(fields[0]) == handle.serverPID, TmuxPaneHandle.identifier(fields[1], prefix: "$"),
                  fields[2] == handle.pane, let pid = Int32(fields[3]), pid > 0, fields[4] == tty,
                  let columns = Int(fields[5]), (1...500).contains(columns), let rows = Int(fields[6]), (1...300).contains(rows),
                  let x = Int(fields[7]), (0...columns).contains(x), let y = Int(fields[8]), (0..<rows).contains(y),
                  [fields[9], fields[11], fields[13], fields[14]].allSatisfy({ $0 == "0" || $0 == "1" }),
                  let modes = Int(fields[12]), modes >= 0 else {
                throw AppError.message("선택한 CLI와 tmux 창의 TTY 또는 식별자가 다릅니다. 다른 창은 연결하지 않습니다.")
            }
            self.session = fields[1]; self.pid = pid; self.columns = columns; self.rows = rows
            // tmux reports x == width while a full last cell is waiting for autowrap.
            // That is a valid pane; an emulator's cursor remains on its last cell.
            self.x = min(x, columns - 1); self.y = y; self.visible = fields[9] == "1"; self.shape = fields[10]; self.blink = fields[11] == "1"
            self.inMode = modes > 0; self.synchronized = fields[13] == "1"; self.inputOff = fields[14] == "1"
        }
    }
    private func handle(_ target: ScreenTarget) throws -> TmuxPaneHandle {
        guard let value = target.handle, let handle = TmuxPaneHandle(encoded: value) else { throw AppError.message("원래 tmux 창의 실행 환경을 확인하지 못했습니다.") }
        try handle.validate(); return handle
    }
    private func run(_ handle: TmuxPaneHandle, _ arguments: [String]) throws -> String {
        guard let executable = Self.executable else { throw AppError.message("이 Mac에 tmux를 설치해주세요.") }
        try handle.validate()
        let result = try CommandRunner.run(executable, ["-S", handle.socket] + arguments, timeout: 2)
        guard result.status == 0 else { throw AppError.message("tmux 연결 결과를 확인하지 못했습니다. 다시 입력하지 말고 원본 창을 확인해주세요. " + String(result.error.prefix(400))) }
        return result.output
    }
    private func link(_ handle: TmuxPaneHandle, tty: String) throws -> TmuxControlConnection {
        let key = handle.encoded
        lock.lock(); defer { lock.unlock() }
        if let link = links[key], link.isRunning { return link }
        guard let executable = Self.executable else { throw AppError.message("이 Mac에 tmux를 설치해주세요.") }
        let pane = try Pane(run(handle, ["display-message", "-p", "-t", handle.pane, Self.metadataFormat]), handle: handle, tty: tty)
        let link = try TmuxControlConnection(executable: executable, socket: handle.socket, session: pane.session, pane: handle.pane)
        links[key] = link
        return link
    }
    public func screen(_ target: ScreenTarget, fresh: Bool = false) throws -> TerminalScreen {
        let handle = try handle(target), link = try link(handle, tty: target.tty)
        let key = handle.encoded + ":" + target.tty
        let version = link.version
        lock.lock(); let previous = cached[key]; lock.unlock()
        if !fresh, let previous, previous.0 == version, Date().timeIntervalSince(previous.1) < 1 { return previous.2 }
        // Capture and cursor metadata are queued together on the existing
        // control connection, each with its own begin/end response.
        let output = try link.command("capture-pane -p -e -t \(handle.pane) ; display-message -p -t \(handle.pane) '\(Self.metadataFormat)'", responses: 2)
        guard let split = output.lastIndex(of: "\n"), split != output.startIndex else { throw AppError.message("tmux 원본 화면 응답이 불완전합니다.") }
        let body = String(output[..<split]), metadata = String(output[output.index(after: split)...])
        let pane = try Pane(metadata, handle: handle, tty: target.tty)
        var lines = body.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        let ansi = "\u{1b}[2J\u{1b}[H" + lines.joined(separator: "\r\n") + "\u{1b}[\(pane.y + 1);\(pane.x + 1)H\u{1b}[?25\(pane.visible && !pane.inMode ? "h" : "l")"
        var result = try OriginalTerminalScreen.render(ansi: ansi, columns: pane.columns, rows: pane.rows, tty: target.tty)
        if var cursor = result.cursor {
            cursor.style = pane.shape == "bar" ? .bar : pane.shape == "underline" ? .underline : .block
            cursor.blink = pane.blink; result.cursor = cursor
        }
        result.title = "tmux \(handle.pane)"
        try handle.validate()
        lock.lock(); cached[key] = (version, Date(), result); lock.unlock()
        return result
    }
    public func observe(_ target: ScreenTarget) throws -> TmuxRelayObservation {
        let handle = try handle(target)
        return TmuxRelayObservation(connection: try link(handle, tty: target.tty))
    }
    func sourceRevision(_ target: ScreenTarget) -> UInt64? {
        guard let value = target.handle, let handle = TmuxPaneHandle(encoded: value) else { return nil }
        lock.lock(); let link = links[handle.encoded]; lock.unlock()
        return link?.version
    }
    public func retain(handles: Set<String>) {
        lock.lock()
        let obsolete = links.filter { key, _ in !handles.contains(key) }
        for key in obsolete.keys { links.removeValue(forKey: key) }
        cached = cached.filter { key, _ in handles.contains(where: { key.hasPrefix($0 + ":") }) }
        lock.unlock()
        for link in obsolete.values { link.stop() }
    }
    private func send(_ target: ScreenTarget, agent: AgentKind, bytes: Data) throws -> TerminalDelivery {
        let handle = try handle(target)
        let connection = try link(handle, tty: target.tty)
        let pane = try Pane(connection.command("display-message -p -t \(handle.pane) '\(Self.metadataFormat)'"), handle: handle, tty: target.tty)
        guard !pane.inMode, !pane.synchronized, !pane.inputOff else {
            throw AppError.message(pane.synchronized ? "tmux의 synchronize-panes가 켜져 있습니다. 다른 창에도 입력되지 않도록 끈 뒤 다시 연결해주세요." : "tmux가 복사 모드이거나 입력이 꺼져 있습니다. Mac에서 같은 창의 입력 상태를 확인해주세요.")
        }
        guard let pid = target.sourcePID, let started = target.sourceStarted, target.jobPIDs.contains(pid),
              Self.currentProcess(pid: pid, started: started, tty: target.tty, agent: agent) != nil,
              Self.hasAncestor(pid: pid, ancestor: pane.pid), Self.hasAncestor(pid: pane.pid, ancestor: handle.serverPID) else { return .agentMissing }
        if let original = target.sourceIdentity {
            guard let current = try? TTYInputIdentity.capture(pid: pid), current.sameProcess(as: original) else { return .agentMissing }
        }
        // Hex arguments preserve exact UTF-8 and control bytes without shell
        // parsing, key-name expansion or Foundation's NFD argument conversion.
        let guardFormat = "#{&&:#{==:#{pane_pid},\(pane.pid)},#{&&:#{==:#{pane_in_mode},0},#{&&:#{==:#{synchronize-panes},0},#{==:#{pane_input_off},0}}}}"
        let keys = bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
        let receipt = UUID().uuidString
        // -F evaluates a tmux format, without executing an if-shell program.
        // Check broadcast/mode/pane identity atomically with the actual write.
        let rejected = UUID().uuidString
        try handle.validate()
        let result = try connection.command("if-shell -F -t \(handle.pane) '\(guardFormat)' 'send-keys -H -t \(handle.pane) \(keys) ; display-message -p \(receipt)' 'display-message -p \(rejected)'", receipt: (receipt, rejected))
        guard result.components(separatedBy: "\n").contains(receipt) else {
            throw AppError.message("tmux 창의 입력 상태가 바뀌었습니다. 다시 보내지 말고 원본 창을 확인해주세요.")
        }
        return .sent
    }
    /// Reads live foreground identity with libproc, without launching ps or
    /// performing any TTY input operation.
    public static func currentProcess(pid: Int32, started: String, tty: String, agent: AgentKind) -> ProcessRecord? {
        guard pid > 0, let identity = try? TTYInputIdentity.capture(pid: pid),
              identity.processStart == started, identity.uid == getuid(), identity.effectiveUID == getuid(),
              identity.processGroup > 0, identity.processGroup == identity.foregroundGroup else { return nil }
        var device = stat(), info = proc_bsdinfo(), path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard lstat(tty, &device) == 0, device.st_mode & S_IFMT == S_IFCHR, device.st_uid == getuid(),
              UInt32(truncatingIfNeeded: device.st_rdev) == identity.device,
              proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
              proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
        let record = ProcessRecord(pid: pid, parent: Int32(info.pbi_ppid), tty: tty.replacingOccurrences(of: "/dev/", with: ""),
            processGroup: identity.processGroup, foregroundGroup: identity.foregroundGroup, started: started, executable: String(cString: path))
        return record.agent == agent ? record : nil
    }
    private static func hasAncestor(pid: Int32, ancestor: Int32) -> Bool {
        var current = pid, seen = Set<Int32>()
        while current > 0, seen.count < 60, seen.insert(current).inserted {
            if current == ancestor { return true }
            var info = proc_bsdinfo(); let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(current, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_uid == getuid() else { return false }
            current = Int32(info.pbi_ppid)
        }
        return false
    }
    public func stop() {
        lock.lock(); let current = Array(links.values); links.removeAll(); cached.removeAll(); lock.unlock()
        for link in current { link.stop() }
    }
}

/// Serial command responses and asynchronous notifications share one pipe.
/// Body text is parsed only inside the matching begin/end response, so pane
/// content resembling a notification cannot invalidate unrelated panes.
fileprivate final class TmuxControlConnection: @unchecked Sendable {
    private let condition = NSCondition(), commands = NSLock()
    private let process = Process(), input = Pipe(), output = Pipe()
    private let pane: String
    private var buffer = Data(), body: [String] = [], responseID: String?
    private var ready = false, closed = false, requested = false, resolved = false
    private var response = "", failure: String?, sequence: UInt64 = 0
    private var receivedResponses = 0, expectedResponses = 1
    private var receipt: (String, String)?
    private var bodyBytes = 0
    private var observers: [UUID: @Sendable () -> Void] = [:]
    init(executable: String, socket: String, session: String, pane: String) throws {
        self.pane = pane
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-u", "-C", "-S", socket, "attach-session", "-E", "-f", "ignore-size", "-t", session]
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "TMUX"); environment.removeValue(forKey: "TMUX_PANE")
        environment["LC_ALL"] = "en_US.UTF-8"; process.environment = environment
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let bytes = handle.availableData
            if bytes.isEmpty { self?.end() } else { self?.consume(bytes) }
        }
        process.terminationHandler = { [weak self] _ in self?.end() }
        do { try process.run() } catch { output.fileHandleForReading.readabilityHandler = nil; throw error }
    }
    var isRunning: Bool { condition.lock(); defer { condition.unlock() }; return !closed && process.isRunning }
    var version: UInt64 { condition.lock(); defer { condition.unlock() }; return sequence }
    func addObserver(_ callback: @escaping @Sendable () -> Void) -> UUID {
        let token = UUID(); condition.lock(); observers[token] = callback; condition.unlock(); return token
    }
    func removeObserver(_ token: UUID) { condition.lock(); observers.removeValue(forKey: token); condition.unlock() }
    func command(_ text: String, responses: Int = 1, receipt: (String, String)? = nil) throws -> String {
        commands.lock(); defer { commands.unlock() }
        condition.lock()
        let deadline = Date().addingTimeInterval(2)
        while !ready && !closed && condition.wait(until: deadline) {}
        guard ready && !closed else { condition.unlock(); throw AppError.message("tmux 원본 관찰 연결이 끊겼습니다.") }
        requested = true; resolved = false; failure = nil; response = ""
        receivedResponses = 0; expectedResponses = responses
        self.receipt = receipt
        condition.unlock()
        do { try input.fileHandleForWriting.write(contentsOf: Data((text + "\n").utf8)) }
        catch { end(); throw error }
        condition.lock()
        while !resolved && !closed && condition.wait(until: deadline) {}
        let success = resolved && !closed, result = response, error = failure
        requested = false; condition.unlock()
        guard success, error == nil else {
            stop()
            throw AppError.message("tmux 화면 응답을 확인하지 못했습니다. " + String((error ?? "연결 시간 초과").prefix(400)))
        }
        return result
    }
    private func consume(_ bytes: Data) {
        condition.lock()
        var changed = false
        defer {
            let callbacks = changed ? Array(observers.values) : []
            condition.unlock()
            for callback in callbacks { callback() }
        }
        guard !closed else { return }
        buffer.append(bytes)
        guard buffer.count <= 4_000_000 else { closed = true; condition.broadcast(); return }
        while let newline = buffer.firstIndex(of: 10) {
            let data = buffer[..<newline]; buffer.removeSubrange(...newline)
            let line = String(decoding: data, as: UTF8.self)
            if let id = responseID {
                if line == "%end " + id || line == "%error " + id {
                    responseID = nil
                    if !ready { ready = true }
                    else if requested {
                        let value = body.joined(separator: "\n")
                        response += (receivedResponses == 0 ? "" : "\n") + value
                        if line.hasPrefix("%error") { failure = value }
                        receivedResponses += 1
                        if let receipt { resolved = response.components(separatedBy: "\n").contains(receipt.0) || response.components(separatedBy: "\n").contains(receipt.1) || failure != nil }
                        else { resolved = receivedResponses >= expectedResponses }
                    }
                    body.removeAll(); bodyBytes = 0; condition.broadcast()
                } else {
                    body.append(line)
                    bodyBytes += line.utf8.count + 1
                    if bodyBytes > 2_000_000 { closed = true; changed = true; condition.broadcast(); return }
                }
            } else if line.hasPrefix("%begin ") {
                responseID = String(line.dropFirst(7)); body.removeAll(); bodyBytes = 0
            } else if line.hasPrefix("%output \(pane) ") || line.hasPrefix("%extended-output \(pane) ") || line.hasPrefix("%pane-mode-changed \(pane)") || line.hasPrefix("%window-") || line.hasPrefix("%layout-change") {
                sequence &+= 1
                changed = true
            } else if line.hasPrefix("%exit") { closed = true; changed = true; condition.broadcast() }
        }
    }
    private func end() {
        condition.lock(); closed = true; let callbacks = Array(observers.values); condition.broadcast(); condition.unlock()
        for callback in callbacks { callback() }
    }
    func stop() {
        end(); output.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() } // Only this observer client, never the server/pane.
    }
    deinit { stop() }
}

/// One HTTP viewer's coalesced wakeup. A slow viewer keeps the latest state,
/// while cancellation detaches only its observer and never replays input.
public final class TmuxRelayObservation: @unchecked Sendable {
    private let lock = NSLock(), connection: TmuxControlConnection
    private var token: UUID?, pending = true
    private var waiter: (UUID, CheckedContinuation<Void, Never>)?
    private var timeout: Task<Void, Never>?
    fileprivate init(connection: TmuxControlConnection) {
        self.connection = connection
        token = connection.addObserver { [weak self] in self?.signal() }
    }
    private func signal() {
        lock.lock(); pending = true; let current = waiter; waiter = nil
        let task = timeout; timeout = nil; lock.unlock()
        task?.cancel(); current?.1.resume()
    }
    private func release(_ id: UUID) {
        lock.lock()
        let current = waiter?.0 == id ? waiter : nil
        if current != nil { waiter = nil; timeout?.cancel(); timeout = nil }
        lock.unlock(); current?.1.resume()
    }
    public func waitForChange(timeout interval: TimeInterval = 1.5) async {
        let id = UUID()
        await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                lock.lock()
                if pending || Task.isCancelled {
                    pending = false; lock.unlock(); continuation.resume(); return
                }
                waiter = (id, continuation)
                timeout = Task { [weak self] in
                    do { try await Task.sleep(for:.seconds(max(0.01,interval))) } catch { return }
                    self?.release(id)
                }
                lock.unlock()
            }
        }, onCancel: { [weak self] in self?.release(id) })
    }
    deinit {
        if let token { connection.removeObserver(token) }
        timeout?.cancel(); waiter?.1.resume()
    }
}
