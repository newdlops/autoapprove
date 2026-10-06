import Foundation
import Combine
import Darwin
import AutoApproveCore

/// Uses production discovery/screen handling with synthetic screens. Never reads or types in a user terminal.
@main struct PollingPerformanceCheck {
    static func check(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        guard condition else { throw AppError.message(message()) }
    }
    final class Frames: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: TerminalScreen] = [:]
        func replace(_ screens: [TerminalScreen]) {
            lock.lock(); defer { lock.unlock() }
            values = Dictionary(uniqueKeysWithValues: screens.map { ($0.tty, $0) })
        }
        func read(_ targets: [ScreenTarget]) -> TerminalSnapshot {
            lock.lock(); defer { lock.unlock() }
            return TerminalSnapshot(screens: targets.compactMap { values[$0.tty] })
        }
    }

    static func screen(index: Int, variant: Int) -> TerminalScreen {
        let agent: AgentKind = index.isMultiple(of: 2) ? .codex : .claude
        let history = (0..<160).map { "Completed synthetic step \($0): checked local output and retained the original session." }.joined(separator: "\n")
        let heading = agent == .codex ? "Would you like to run the following command?" : "Do you want to proceed?"
        let glyph = agent == .codex ? "›" : "❯"
        let body: String
        switch index / 4 {
        case 0: body = "Checking synthetic result \(variant)\n• Working (esc to interrupt)"
        case 1: body = "\(glyph)\n? for shortcuts"
        case 2: body = "\(heading)\n  $ fixture-test-\(variant)\n\(glyph) 1. Yes\n  2. No\nEsc to cancel"
        default: body = "Which synthetic result \(variant) should we inspect?\n\(glyph) 1. First\n  2. Second\nEnter to select"
        }
        return TerminalScreen(tty: "/dev/fixture-perf-\(index)", contents: history + "\n" + body, title: "Synthetic terminal \(index)")
    }

    static func cpu(_ who: Int32 = RUSAGE_SELF) -> Double {
        var usage = rusage(); getrusage(who, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }

    @MainActor static func main() async {
        do { try await run() }
        catch { FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(1) }
    }

    @MainActor static func run() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let frames = Frames()
        let adapter = ScreenHostAdapter(screens: { frames.read($0) }, approve: { _, _, _ in fatalError("Benchmark must never send approval input") }, reveal: { _ in nil })
        let engine = try ApprovalEngine(paths: AppPaths(directory: root.appendingPathComponent("state")), claudeRegistryReader: { _ in [] }, screenAdapters: [.terminal: adapter])
        defer { engine.stop() }
        let sessions = (0..<16).map { index in
            AgentSession(id: "process:\(900_000 + index):perf", agent: index.isMultiple(of: 2) ? .codex : .claude,
                pid: Int32(900_000 + index), started: "perf", tty: "/dev/fixture-perf-\(index)", cwd: root.path, terminal: .terminal)
        }
        engine.updateDiscovery(sessions, records: [])
        frames.replace((0..<16).map { screen(index: $0, variant: 0) })
        await engine.connectScreenHost(.terminal)
        var publications = 0
        var tracker = AttentionTracker()
        let subscription = engine.$snapshot.dropFirst().sink { snapshot in
            publications += 1
            _ = tracker.update(snapshot) + AttentionRequest.completions(snapshot)
        }
        defer { subscription.cancel() }
        var workloads: [[String: Any]] = []
        for changed in [false, true] {
            publications = 0
            let beforeCPU = cpu(), beforeWall = Date()
            for round in 0..<50 {
                if changed { frames.replace((0..<16).map { screen(index: $0, variant: round + 1) }) }
                await engine.refreshScreenHost(.terminal)
            }
            let report: [String: Any] = ["name": changed ? "changing-screens" : "unchanged-screens", "rounds": 50,
                "sessions": 16, "cpuSeconds": cpu() - beforeCPU, "wallSeconds": Date().timeIntervalSince(beforeWall), "publications": publications]
            workloads.append(report)
            let phases = Dictionary(grouping: engine.snapshot.sessions, by: { $0.phase.rawValue }).mapValues(\.count)
            try check(phases["working"] == 4, "Working phase count: \(phases)")
            try check(phases["approval"] == 4, "Approval phase count: \(phases)")
            try check(phases["input"] == 4, "Input phase count: \(phases)")
            try check(engine.snapshot.sessions.allSatisfy { !$0.automatic }, "Unexpected automatic policy")
            try check(engine.snapshot.events.isEmpty, "Unexpected audit event")
        }

        // Freshness and the two-second idle confirmation must still run for identical text.
        for index in 4..<8 {
            engine.receiveScreen(sessionID: sessions[index].id, raw: screen(index: index, variant: 50).contents,
                generation: "terminal:" + sessions[index].id, at: Date().addingTimeInterval(3))
        }
        try check(engine.snapshot.sessions.filter { $0.phase == .idle }.count == 4, "Idle confirmation did not preserve four idle sessions")

        // Real cwd reads are limited to lightweight children created by this fixture.
        var children: [Process] = []
        defer { for child in children where child.isRunning { child.terminate(); child.waitUntilExit() } }
        var expected: [Int32: String] = [:]
        for index in 0..<16 {
            let directory = root.appendingPathComponent("cwd-\(index) path")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let child = Process(); child.executableURL = URL(fileURLWithPath: "/bin/sleep"); child.arguments = ["60"]
            child.currentDirectoryURL = directory; child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
            try child.run(); children.append(child)
            expected[child.processIdentifier] = directory.path
        }
        let beforeCPU = cpu() + cpu(RUSAGE_CHILDREN), beforeWall = Date()
        for _ in 0..<20 {
            let actual = ProcessDiscovery.workingDirectories(pids: Array(expected.keys))
            try check(actual == expected, "cwd mismatch: expected \(expected.count), found \(actual.count), unequal \(expected.keys.filter { actual[$0] != expected[$0] }.count)")
        }
        workloads.append(["name": "working-directories", "rounds": 20, "sessions": 16,
            "cpuSeconds": cpu() + cpu(RUSAGE_CHILDREN) - beforeCPU, "wallSeconds": Date().timeIntervalSince(beforeWall)])
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        let report: [String: Any] = ["workloads": workloads, "peakResidentBytes": usage.ru_maxrss,
            "preserved": ["16 exact sessions", "all phases", "idle confirmation", "no input", "no audit events", "exact cwd with spaces"]]
        print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
    }
}
