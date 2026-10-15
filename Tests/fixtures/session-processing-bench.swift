import Foundation
import Combine
import Darwin
import AutoApproveCore

/// Synthetic process/metadata work only. Never reads or writes a user terminal.
@main struct SessionProcessingBench {
    static func cpu() -> Double {
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }

    @MainActor static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let paths = AppPaths(directory: root)
        var records = ProcessDiscovery.parse("1 0 ?? 1 0 Mon Sep 21 09:00:00 2026 /sbin/launchd")
        for index in 0..<1200 {
            records += ProcessDiscovery.parse("\(index + 100) 1 ?? 1 0 Mon Sep 21 09:00:00 2026 /fixture/system/worker-\(index)")
        }
        for index in 0..<24 {
            records += ProcessDiscovery.parse("""
            \(7000 + index) 1 ttys\(index + 500) \(7000 + index) \(9000 + index) Mon Sep 21 09:00:00 2026 /bin/zsh
            \(9000 + index) \(7000 + index) ttys\(index + 500) \(9000 + index) \(9000 + index) Mon Sep 21 09:00:01 2026 \(index.isMultiple(of: 2) ? "/fixture/codex" : "/fixture/claude/versions/2.1.0")
            """)
        }
        var reports: [[String: Any]] = []
        func measure(_ name: String, rounds: Int, _ body: () throws -> Int) rethrows {
            let beforeCPU = cpu(), start = Date()
            var checksum = 0
            for _ in 0..<rounds { checksum += try body() }
            reports.append(["name": name, "rounds": rounds, "cpuSeconds": cpu() - beforeCPU,
                "wallSeconds": Date().timeIntervalSince(start), "checksum": checksum])
        }
        measure("process-classification", rounds: 200) {
            records.reduce(0) { $0 + ($1.agent == nil ? 0 : 1) }
        }
        measure("process-discovery", rounds: 100) {
            ProcessDiscovery.sessions(records, environment: { _ in [:] }).count
        }
        var sessions = ProcessDiscovery.sessions(records, environment: { _ in [:] })
        for index in sessions.indices {
            sessions[index].cwd = "/fixture/projects/Project \(23 - index) 한글"
        }
        // Persist the same exact parent IDs used in the live projection, including a
        // grandchild. The registry and every screen adapter remain synthetic.
        var parents: [String: String] = [:]
        let claude = sessions.filter { $0.agent == .claude }
        for (index, child) in claude.dropFirst().enumerated() {
            parents[child.id] = index.isMultiple(of: 3) && index > 0 ? claude[1].id : claude[0].id
        }
        try paths.prepare()
        let store = try AuditStore(path: paths.database)
        try store.set("claudeParents", String(decoding: try JSONEncoder().encode(parents), as: UTF8.self))
        let engine = try ApprovalEngine(paths: paths, claudeRegistryReader: { _ in [] })
        defer { engine.stop() }
        engine.updateDiscovery(sessions, records: records, claudeRegistrations: [])
        var publications = 0
        let subscription = engine.$snapshot.dropFirst().sink { _ in publications += 1 }
        defer { subscription.cancel() }
        measure("session-projection", rounds: 200) {
            engine.refreshNotices()
            return engine.snapshot.sessions.count + engine.snapshot.sessions.reduce(0) { $0 + $1.backgroundChildren.count }
        }
        guard reports[0]["checksum"] as? Int == 4800,
              reports[1]["checksum"] as? Int == 2400,
              reports[2]["checksum"] as? Int == 4800,
              publications == 0, engine.snapshot.events.isEmpty,
              engine.snapshot.sessions.first(where: { $0.id == claude[0].id })?.backgroundChildren.count == 11 else {
            throw AppError.message("Synthetic classification/projection changed")
        }
        print(String(decoding: try JSONSerialization.data(withJSONObject: ["workloads": reports,
            "publications": publications, "records": records.count, "sessions": sessions.count], options: [.sortedKeys]), as: UTF8.self))
    }
}
