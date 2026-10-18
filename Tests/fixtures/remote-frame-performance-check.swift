import Foundation
import Darwin
import AutoApproveCore

/// Production frame construction with one synthetic original. No listeners,
/// native apps, terminal input, process discovery or screenshots.
@main struct RemoteFramePerformanceCheck {
    static func cpu() -> Double {
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }

    @MainActor static func main() async {
        do { try await run() }
        catch { fputs("Remote frame benchmark failed: \(error)\n", stderr); exit(1) }
    }

    @MainActor static func run() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let history = String(repeating: "Synthetic scrollback /fixture/output.swift: preserved original output.\n", count: 2_500)
        let menu = "Which synthetic screen should we inspect?\n\n› 1. Phone layout\n  2. Desktop layout\n\nPress enter to confirm or esc to cancel"
        var workloads: [[String: Any]] = []
        for choice in [false, true] {
            let raw = history + (choice ? menu : "Working\nesc to interrupt")
            let record = ProcessDiscovery.parse("420000 1 ttys099 420000 420000 Mon Oct 5 09:00:00 2026 codex")[0]
            let session = AgentSession(id: record.key, agent: .codex, pid: record.pid, started: record.started,
                tty: "/dev/ttys099", cwd: root.path, terminal: .iterm)
            let adapter = ScreenHostAdapter(screens: { targets in
                TerminalSnapshot(screens: targets.map { TerminalScreen(tty: $0.tty, contents: raw) })
            }, approve: { _, _, _ in fatalError("Benchmark cannot approve") }, reveal: { _ in nil })
            let engine = try ApprovalEngine(paths: AppPaths(directory: root.appendingPathComponent(choice ? "choice" : "plain")),
                claudeRegistryReader: { _ in [] }, processReader: { [record] }, screenAdapters: [.iterm: adapter],
                terminalInputAvailable: { false }, terminalInputIdentity: { _ in nil })
            engine.updateDiscovery([session], records: [record]); await engine.connectScreenHost(.iterm)
            let initial = try await engine.remoteTerminal(sessionID: session.id, realtime: true)
            let expectedScreen = String(raw.suffix(160_000))
            let beforeCPU = cpu(), beforeWall = ProcessInfo.processInfo.systemUptime
            for _ in 0..<128 {
                let frame = try await engine.remoteTerminal(sessionID: session.id, realtime: true)
                guard frame.screen == expectedScreen, frame.revision == initial.revision,
                      frame.streamID == initial.streamID, (frame.question != nil) == choice,
                      frame.question?.options == initial.question?.options else {
                    throw AppError.message("Repeated frame changed its original text, revision, stream or question")
                }
            }
            workloads.append(["name": choice ? "remote-choice" : "remote-plain", "rounds": 128,
                "screenBytes": raw.utf8.count, "cpuSeconds": cpu() - beforeCPU,
                "wallSeconds": ProcessInfo.processInfo.systemUptime - beforeWall])
            guard engine.snapshot.events.isEmpty, engine.managedPTY.inventory.isEmpty else {
                throw AppError.message("Benchmark produced an audit event or a PTY")
            }
            engine.stop()
        }
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        print(String(decoding: try JSONSerialization.data(withJSONObject: ["workloads": workloads,
            "peakResidentBytes": usage.ru_maxrss, "preserved": ["exact text", "revision", "stream identity", "question options", "no input", "no PTY"]],
            options: [.sortedKeys]), as: UTF8.self))
    }
}
