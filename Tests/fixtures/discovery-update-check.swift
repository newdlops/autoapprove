import Foundation
import Combine
import Darwin
import AutoApproveCore

/// Real engine updates with synthetic processes and isolated preferences only.
/// The engine is never started; no screen adapter, input or LAN work runs.
@main struct DiscoveryUpdateCheck {
    static func cpu() -> Double {
        var value = rusage(); getrusage(RUSAGE_SELF,&value)
        return Double(value.ru_utime.tv_sec+value.ru_stime.tv_sec)
            + Double(value.ru_utime.tv_usec+value.ru_stime.tv_usec)/1_000_000
    }
    @MainActor static func main() throws {
        let root = URL(fileURLWithPath:CommandLine.arguments[1])
        var records = ProcessDiscovery.parse("1 0 ?? 1 0 Mon Sep 21 09:00:00 2026 /sbin/launchd")
        for index in 0..<1200 {
            records += ProcessDiscovery.parse("\(index+100) 1 ?? 1 0 Mon Sep 21 09:00:00 2026 /fixture/worker-\(index)")
        }
        for index in 0..<24 {
            records += ProcessDiscovery.parse("""
            \(7000+index) 1 ttys\(index+500) \(7000+index) \(9000+index) Mon Sep 21 09:00:00 2026 /bin/zsh
            \(9000+index) \(7000+index) ttys\(index+500) \(9000+index) \(9000+index) Mon Sep 21 09:00:01 2026 /fixture/codex
            """)
        }
        var sessions = ProcessDiscovery.sessions(records,environment:{_ in [:]})
        precondition(sessions.count == 24)
        for index in sessions.indices { sessions[index].cwd = "/fixture/project-\(index)" }
        var reports: [[String:Any]] = []
        for automatic in [false,true] {
            let paths = AppPaths(directory:root.appendingPathComponent(automatic ? "automatic" : "manual"))
            try paths.prepare()
            let store = try AuditStore(path:paths.database)
            if automatic { for session in sessions { try store.set("automatic:"+session.id,"true") } }
            let engine = try ApprovalEngine(paths:paths,claudeRegistryReader:{_ in []})
            defer { engine.stop() }
            engine.updateDiscovery(sessions,records:records,claudeRegistrations:[])
            precondition(engine.snapshot.sessions.count == 24)
            precondition(engine.snapshot.sessions.filter(\.automatic).count == (automatic ? 24 : 0))
            var publications = 0
            let subscription = engine.$snapshot.dropFirst().sink {_ in publications += 1}
            defer { subscription.cancel() }
            let beforeCPU = cpu(), before = ProcessInfo.processInfo.systemUptime
            for _ in 0..<200 { engine.updateDiscovery(sessions,records:records,claudeRegistrations:[]) }
            let elapsed = ProcessInfo.processInfo.systemUptime-before, consumed = cpu()-beforeCPU
            precondition(publications == 0 && engine.snapshot.events.isEmpty)
            precondition(engine.snapshot.sessions.filter(\.automatic).count == (automatic ? 24 : 0))
            reports.append(["automatic":automatic,"rounds":200,"cpuSeconds":consumed,
                "wallSeconds":elapsed,"publications":publications])
        }
        print(String(decoding:try JSONSerialization.data(withJSONObject:["records":records.count,
            "sessions":sessions.count,"workloads":reports,"inputPosts":0],options:[.sortedKeys]),as:UTF8.self))
    }
}
