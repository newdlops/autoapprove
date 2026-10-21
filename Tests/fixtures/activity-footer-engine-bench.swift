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

    static func screen(index: Int, variant: Int, kind: String) -> TerminalScreen {
        let agent: AgentKind = index.isMultiple(of: 2) ? .codex : .claude
        let detail = kind.hasPrefix("mixed") ? "합성 출력 e\u{301} 👩🏽‍💻" : "ASCII output"
        let history = (0..<160).map { "Completed synthetic step \($0): checked \(detail) local output and retained the original session." }.joined(separator: "\n")
        let heading = agent == .codex ? "Would you like to run the following command?" : "Do you want to proceed?"
        let glyph = agent == .codex ? "›" : "❯"
        let body: String
        switch index / 4 {
        case 0: body = "Checking synthetic result \(variant)\n• Working (esc to interrupt)"
        case 1: body = "\(glyph)\n? for shortcuts"
        case 2: body = "\(heading)\n  $ fixture-test-\(variant)\n\(glyph) 1. Yes\n  2. No\nEsc to cancel"
        default: body = "Which synthetic result \(variant) should we inspect?\n\(glyph) 1. First\n  2. Second\nEnter to select"
        }
        let text = history + "\nIgnored body revision \(variant)\n" + String(repeating: "Unchanged visible context\n", count: 20) + body
        let contents = kind.hasSuffix("cocoa") ? NSAppleEventDescriptor(string: text).stringValue! : text
        return TerminalScreen(tty: "/dev/fixture-perf-\(index)", contents: contents, title: "Synthetic terminal \(index)")
    }

    static func cpu(_ who: Int32 = RUSAGE_SELF) -> Double {
        var usage = rusage(); getrusage(who, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }

    @MainActor static func main() async {
        do {
            let original = ["ascii-native", "mixed-native", "ascii-cocoa", "mixed-cocoa"]
            let offset = Int(CommandLine.arguments.last!)! % original.count
            let kinds = Array(original[offset...] + original[..<offset])
            var reports: [[String: Any]] = []
            for kind in kinds { reports.append(try await run(kind: kind)) }
            print(String(decoding: try JSONSerialization.data(withJSONObject: ["kinds": reports, "terminalInputs": 0, "captures": 0, "listeners": 0], options: [.sortedKeys]), as: UTF8.self))
        }
        catch { FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(1) }
    }

    @MainActor static func run(kind: String) async throws -> [String: Any] {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(kind)
        let frames = Frames()
        let adapter = ScreenHostAdapter(screens: { frames.read($0) }, approve: { _, _, _ in fatalError("Benchmark must never send approval input") }, reveal: { _ in nil })
        let engine = try ApprovalEngine(paths: AppPaths(directory: root.appendingPathComponent("state")), claudeRegistryReader: { _ in [] }, processReader: { [] }, screenAdapters: [.terminal: adapter])
        defer { engine.stop() }
        let sessions = (0..<16).map { index in
            AgentSession(id: "process:\(900_000 + index):perf", agent: index.isMultiple(of: 2) ? .codex : .claude,
                pid: Int32(900_000 + index), started: "perf", tty: "/dev/fixture-perf-\(index)", cwd: root.path, terminal: .terminal)
        }
        engine.updateDiscovery(sessions, records: [])
        let variants = (0...1).map { variant in (0..<16).map { screen(index: $0, variant: variant, kind: kind) } }
        frames.replace(variants[0])
        await engine.connectScreenHost(.terminal)
        var publications = 0
        var tracker = AttentionTracker()
        let subscription = engine.$snapshot.dropFirst().sink { snapshot in
            publications += 1
            _ = tracker.update(snapshot) + AttentionRequest.completions(snapshot)
        }
        defer { subscription.cancel() }
        let rounds = Int(CommandLine.arguments[2])!
        let foreignFrames = variants.flatMap { $0 }.filter { !$0.contents.isContiguousUTF8 }.count
        try check(foreignFrames == (kind.hasSuffix("cocoa") ? 32 : 0), "Frame banks must preserve selected storage")
        print("PROFILE_READY"); fflush(stdout)
        try await Task.sleep(for: .milliseconds(2200))
        await engine.refreshScreenHost(.terminal)
        var workloads: [[String: Any]] = []
        for changed in [false, true] {
            if changed { print("PROFILE_CHANGING"); fflush(stdout) }
            publications = 0
            let beforeCPU = cpu(), beforeWall = Date()
            for round in 0..<rounds {
                if changed { frames.replace(variants[(round+1)%2]) }
                await engine.refreshScreenHost(.terminal)
            }
            let report: [String: Any] = ["name": changed ? "changing-screens" : "unchanged-screens", "rounds": rounds,
                "sessions": 16, "cpuSeconds": cpu() - beforeCPU, "wallSeconds": Date().timeIntervalSince(beforeWall), "publications": publications, "phaseCounts": Dictionary(grouping: engine.snapshot.sessions, by: { $0.phase.rawValue }).mapValues(\.count)]
            workloads.append(report)
            let phases = Dictionary(grouping: engine.snapshot.sessions, by: { $0.phase.rawValue }).mapValues(\.count)
            try check(phases["working"] == 4, "Working phase count: \(phases)")
            try check(phases["approval"] == 4, "Approval phase count: \(phases)")
            try check(phases["input"] == 4, "Input phase count: \(phases)")
            try check(engine.snapshot.sessions.allSatisfy { !$0.automatic }, "Unexpected automatic policy")
            try check(engine.snapshot.events.isEmpty, "Unexpected audit event")
        }

        try check(engine.snapshot.events.isEmpty, "Unexpected input audit")
        try check(engine.managedPTY.inventory.isEmpty, "Unexpected PTY")
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        let report: [String: Any] = ["workloads": workloads, "peakResidentBytes": usage.ru_maxrss,
            "terminalInputs": 0, "captures": 0, "scope": "Release Core comparison, 16 synthetic Terminal adapters, two prebuilt Cocoa screen banks; no engine start/listener/native reads/input."]
        return report.merging(["kind": kind, "foreignFrames": foreignFrames]) { _, fresh in fresh }
    }
}
