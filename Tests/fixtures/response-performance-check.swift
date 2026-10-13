import Foundation
import Darwin
import AutoApproveCore

/// Synthetic adapters never read or type in a user's terminal. The only child
/// commands in this workload are bounded sleeps owned by the fixture.
@main struct ResponsePerformanceCheck {
    final class Probe: @unchecked Sendable {
        private let lock = NSLock()
        var slow = false
        private var value = "Working\nesc to interrupt"
        private var slowEntered = false
        private var counts: [String: Int] = [:]
        func arm() { lock.lock(); slow = true; lock.unlock() }
        func set(_ text: String) { lock.lock(); value = text; lock.unlock() }
        func count(_ key: String) -> Int { lock.lock(); defer { lock.unlock() }; return counts[key] ?? 0 }
        func add(_ key: String) { lock.lock(); counts[key, default: 0] += 1; lock.unlock() }
        var entered: Bool { lock.lock(); defer { lock.unlock() }; return slowEntered }
        func read(_ targets: [ScreenTarget], host: ScreenHost) -> TerminalSnapshot {
            lock.lock(); let pause = host == .orca && slow
            if pause { slowEntered = true }
            let raw = value; counts[host.rawValue, default: 0] += 1; lock.unlock()
            if pause { Thread.sleep(forTimeInterval: 3) }
            return TerminalSnapshot(screens: targets.map { TerminalScreen(tty: $0.tty, contents: raw) })
        }
    }
    static func cpu() -> Double {
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }
    @MainActor static func wait(_ predicate: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 14
        while !predicate(), ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(for: .milliseconds(10)) }
        guard predicate() else { throw AppError.message("Synthetic response workload timed out") }
    }
    @MainActor static func main() async throws {
        if CommandLine.arguments.contains("--park") { try await Task.sleep(for: .seconds(60)); return }
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), probe = Probe()
        let startCPU = cpu(), start = ProcessInfo.processInfo.systemUptime
        for _ in 0..<40 { _ = try CommandRunner.run("/bin/sleep", ["0.06"], timeout: 2) }
        let commandCPU = cpu() - startCPU, commandWall = ProcessInfo.processInfo.systemUptime - start
        // The kernel launch-environment reader requires a real PID/start pair.
        // This bounded child exports only a synthetic pane handle; it is never
        // an actual provider or emulator, and no input is sent to it.
        let child = Process(); child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]); child.arguments = ["--park"]
        child.environment = ProcessInfo.processInfo.environment.merging(["TERM_PROGRAM": "Orca", "ORCA_TERMINAL_HANDLE": "synthetic-slow-pane"]) { _, value in value }
        child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
        try child.run(); defer { if child.isRunning { child.terminate(); child.waitUntilExit() } }
        guard var slowOwner = try ProcessDiscovery.read(pid: child.processIdentifier).first else { throw AppError.message("Synthetic child identity missing") }
        slowOwner.tty = "ttys981"; slowOwner.processGroup = slowOwner.pid; slowOwner.foregroundGroup = slowOwner.pid
        slowOwner.parent = 900012; slowOwner.executable = "/usr/local/bin/claude"
        let records = ProcessDiscovery.parse("""
        900001 900011 ttys980 900001 900001 Mon Sep 21 09:00:00 2026 /usr/local/bin/claude
        900011 1 ?? 900011 0 Mon Sep 21 08:00:00 2026 /System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal
        900012 1 ?? 900012 0 Mon Sep 21 08:00:00 2026 /Applications/Orca.app/Contents/MacOS/Orca
        """) + [slowOwner]
        var adapters = Dictionary(uniqueKeysWithValues: ScreenHost.allCases.map { host in
            (host, ScreenHostAdapter(screens: { probe.read($0, host: host) },
                approve: { target, _, _ in guard target.sourcePID == 900001 else { return .missingTarget }; probe.add("approved"); return .sent },
                reveal: { _ in nil }, resume: { target, _, text in
                    guard target.sourcePID == 900001, text == CodexCapacityStop.resumeText else { return .missingTarget }
                    probe.add("resumed"); return .sent
                }))
        })
        // Empty hosts never touch any native emulator.
        for host in [ScreenHost.iterm, .tmux, .pty] { adapters[host]?.screens = { _ in TerminalSnapshot() } }
        let engine = try ApprovalEngine(paths: AppPaths(directory: root), claudeRegistryReader: { _ in [] }, processReader: { probe.add("processReads"); return records }, screenAdapters: adapters)
        defer { engine.stop() }
        let found = ProcessDiscovery.sessions(records)
        guard found.count == 2, found.first(where: { $0.pid == 900001 })?.terminal == .terminal,
              found.first(where: { $0.pid == slowOwner.pid })?.terminal == .orca else { throw AppError.message("Synthetic host identity failed") }
        engine.updateDiscovery(found, records: records)
        await engine.connectScreenHost(.terminal); await engine.connectScreenHost(.orca)
        try engine.setAutomatic(records[0].key, enabled: true)
        probe.arm(); try engine.start()
        try await wait { probe.entered }
        let approvalStart = ProcessInfo.processInfo.systemUptime
        probe.set("Do you want to proceed?\n$ fixture-test\n❯ 1. Yes\n  2. No\nEsc to cancel")
        try await wait { probe.count("approved") == 1 }
        let approvalSeconds = ProcessInfo.processInfo.systemUptime - approvalStart
        engine.interruptionResumeDelays = [0.1]
        let recoveryStart = ProcessInfo.processInfo.systemUptime
        probe.set("Earlier task\n\nAPI Error: Connection error.\n\n❯ \n? for shortcuts")
        try await wait { probe.count("resumed") == 1 }
        let recoverySeconds = ProcessInfo.processInfo.systemUptime - recoveryStart
        let activeReads = probe.count("terminal")
        try engine.setPaused(true)
        let quietStart = ProcessInfo.processInfo.systemUptime
        let beforeQuiet = probe.count("terminal")
        try await Task.sleep(for: .seconds(4.2))
        let quietReads = probe.count("terminal") - beforeQuiet
        let report: [String: Any] = ["commandCount": 40, "commandCPUSeconds": commandCPU, "commandWallSeconds": commandWall,
            "slowHostSeconds": 3, "approvalSeconds": approvalSeconds, "recoverySeconds": recoverySeconds,
            "activeTerminalReads": activeReads, "quietTerminalReads": quietReads, "quietSeconds": ProcessInfo.processInfo.systemUptime - quietStart,
            "processReads": probe.count("processReads"), "approvals": probe.count("approved"), "continuations": probe.count("resumed")]
        print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
    }
}
