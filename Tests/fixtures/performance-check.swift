import Foundation
import Combine
import Darwin
import AutoApproveCore

/// An isolated, deterministic workload. No polling, real terminal reads or replies.
@main struct PerformanceCheck {
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let engine = try ApprovalEngine(paths: AppPaths(directory: root), claudeRegistryReader: { _ in [] })
        var records = ProcessDiscovery.parse("1 0 ?? 1 0 Mon Sep 21 09:00:00 2026 /sbin/launchd")
        for index in 0..<800 {
            records += ProcessDiscovery.parse("\(index + 100) 1 ?? 1 0 Mon Sep 21 09:00:00 2026 /fixture/worker")
        }
        for index in 0..<15 {
            records += ProcessDiscovery.parse("""
            \(7000 + index) 1 ttys\(index + 500) \(7000 + index) \(9000 + index) Mon Sep 21 09:00:00 2026 /bin/zsh
            \(9000 + index) \(7000 + index) ttys\(index + 500) \(9000 + index) \(9000 + index) Mon Sep 21 09:00:01 2026 /fixture/codex
            """)
        }
        let sessions = ProcessDiscovery.sessions(records)
        engine.updateDiscovery(sessions, records: records)
        let questions = (0..<8).map {
            QueuedQuestion(id: "fixture-question-\($0)", threadID: "fixture", title: "작업 \($0)을 진행할까요?", options: ["예", "아니오"])
        }
        engine.updateCodexQuestions([.init(sessionID: sessions[0].id, questions: questions, threadID: "fixture")])
        try engine.start(poll: false)
        defer { engine.stop() }
        var publications = 0
        let subscription = engine.$snapshot.dropFirst().sink { _ in publications += 1 }
        print("READY")
        fflush(stdout)
        // The driver holds its bridge connections open until measurements finish.
        _ = await Task.detached { readLine() }.value
        withExtendedLifetime(subscription) {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            let cpu = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
                + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
            let report: [String: Any] = ["publications": publications, "cpuSeconds": cpu, "sessions": engine.snapshot.sessions.count]
            print(String(decoding: try! JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
            fflush(stdout)
        }
    }
}
