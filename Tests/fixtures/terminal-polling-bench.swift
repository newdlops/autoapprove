import Foundation
import Darwin
import AutoApproveCore

private final class BenchScreens: @unchecked Sendable {
    let lock = NSLock(), directory: URL
    var singleReads = 0, batchReads = 0, values: [String: String] = [:]
    init(_ directory: URL) { self.directory = directory }
    func read(_ targets: [ScreenTarget]) -> TerminalSnapshot {
        lock.lock(); defer { lock.unlock() }
        if targets.count == 1 { singleReads += 1 } else { batchReads += 1 }
        return TerminalSnapshot(screens: targets.map { TerminalScreen(tty: $0.tty, contents: values[$0.tty] ?? "Polling QA\n›\n? for shortcuts", title: "Isolated benchmark") })
    }
    func input(_ target: ScreenTarget, _ input: RemoteTerminalInput) -> TerminalDelivery {
        lock.lock(); defer { lock.unlock() }
        values[target.tty, default: "Polling QA\n›\n? for shortcuts"] += input.bytes
        return .sent
    }
    func report() -> [String: Int] { lock.lock(); defer { lock.unlock() }; return ["singleReads":singleReads,"batchReads":batchReads] }
}

@main struct TerminalPollingBench {
    @MainActor static func main() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1]), count = Int(CommandLine.arguments[2])!
        let rows = (0..<count).map { "\(91001+$0) 1 ttys\(200+$0) \(91001+$0) \(91001+$0) Mon Sep 21 09:00:01 2026 /fixture/codex" }.joined(separator:"\n")
        let records = ProcessDiscovery.parse(rows), screens = BenchScreens(directory)
        let adapter = ScreenHostAdapter(screens: { screens.read($0) }, approve: { _,_,_ in .missingTarget }, reveal: { _ in nil }, input: { target,_,_,input in screens.input(target,input) })
        let engine = try ApprovalEngine(paths: AppPaths(directory: directory.appendingPathComponent("profile")), processReader: { records }, screenAdapters: [.iterm:adapter])
        defer { engine.stop() }
        var sessions = ProcessDiscovery.sessions(records)
        for i in sessions.indices { sessions[i].terminal = .iterm; sessions[i].cwd = "/fixture/polling" }
        engine.updateDiscovery(sessions, records: records); await engine.connectScreenHost(.iterm)
        let web = RemoteNetworkService(engine: engine, nodeID: UUID().uuidString, name:"Isolated polling benchmark", bonjourEnabled:false, discoveryAddresses:{[]}) { status in
            if status.ready, let port = status.port { try? Data(String(port).utf8).write(to:directory.appendingPathComponent("port")) }
        }
        defer { web.stop() }; try web.start(port:0)
        let start = ProcessInfo.processInfo.systemUptime
        while !Task.isCancelled {
            await engine.refreshScreenHost(.iterm)
            var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
            var report: JSONObject = screens.report().mapValues { $0 as Any }
            report["cpuSeconds"] = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
            report["seconds"] = ProcessInfo.processInfo.systemUptime - start
            report["sessions"] = engine.snapshot.sessions.count
            try JSONSerialization.data(withJSONObject:report).write(to:directory.appendingPathComponent("stats.json"), options:.atomic)
            try await Task.sleep(for:.milliseconds(500))
        }
    }
}
