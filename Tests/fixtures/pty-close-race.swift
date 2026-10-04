import Foundation
import AutoApproveCore

private final class ScreenGate: @unchecked Sendable {
    private let lock = NSLock()
    private let released = DispatchSemaphore(value: 0)
    private var entered = false
    var waiting: Bool { lock.lock(); defer { lock.unlock() }; return entered }
    func read() -> TerminalSnapshot {
        lock.lock(); entered = true; lock.unlock()
        released.wait()
        return TerminalSnapshot(screens: [])
    }
    func release() { released.signal() }
}

@main struct PTYCloseRace {
    @MainActor static func main() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        let gate = ScreenGate()
        let environment = ProcessInfo.processInfo.environment.merging(["HOME": directory.path, "ZDOTDIR": directory.path, "PATH": directory.path + ":/usr/bin:/bin"]) { _, value in value }
        let manager = ManagedPTYManager(environment: environment)
        let engine = try ApprovalEngine(paths: AppPaths(directory: directory.appendingPathComponent("race")),
            claudeRegistryReader: { _ in [] }, processReader: { [] },
            screenAdapters: [.pty: ScreenHostAdapter(screens: { _ in gate.read() }, approve: { _, _, _ in .missingTarget }, reveal: { _ in nil })], managedPTY: manager)
        defer { gate.release(); engine.stop() }
        let pty = try manager.create(cwd: directory.path, program: "codex", command: [directory.appendingPathComponent("codex").path], columns: 80, rows: 24)
        let discovered = AgentSession(id: "process:\(pty.pid):fixture", agent: .codex, pid: pty.pid, started: "fixture", tty: pty.tty, cwd: directory.path, terminal: .terminal)
        engine.updateDiscovery([discovered], records: [])
        let screenRead = Task { await engine.refreshScreenHost(.pty) }
        for _ in 0..<300 where !gate.waiting { try await Task.sleep(nanoseconds: 10_000_000) }
        guard gate.waiting else { throw AppError.message("Race fixture did not enter its screen read") }
        _ = try engine.ptyClose(["ptyID": pty.ptyID, "streamID": pty.streamID])
        gate.release(); await screenRead.value
        try engine.setPaused(true)
        guard !engine.snapshot.sessions.contains(where: { $0.pid == pty.pid && $0.phase != .ended }) else {
            throw AppError.message("A delayed empty screen read revived the explicitly closed PTY")
        }
        engine.updateDiscovery([discovered], records: [])
        guard !engine.snapshot.sessions.contains(where: { $0.pid == pty.pid && $0.phase != .ended }) else {
            throw AppError.message("A delayed discovery record revived the explicitly closed PTY")
        }
        print("PASS delayed screen and discovery results cannot revive a closed PTY")
    }
}
