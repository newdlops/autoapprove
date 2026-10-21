import Foundation
import Darwin
import AutoApproveCore

private final class ProbeStop: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    func finish() { lock.lock(); stopped = true; lock.unlock() }
    func isFinished() -> Bool { lock.lock(); defer { lock.unlock() }; return stopped }
}

@MainActor private final class ActorProbe {
    var delays: [Double] = []
    func record(_ requested: TimeInterval) {
        delays.append(ProcessInfo.processInfo.systemUptime - requested)
    }
}

@main private enum DashboardActorBench {
    static func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw AppError.message(message) }
    }
    static func cpu(_ who: Int32 = RUSAGE_SELF) -> Double {
        var value = rusage(); precondition(getrusage(who, &value) == 0)
        return Double(value.ru_utime.tv_sec + value.ru_stime.tv_sec) + Double(value.ru_utime.tv_usec + value.ru_stime.tv_usec) / 1e6
    }
    static func percentile(_ values: [Double], _ fraction: Double) -> Double {
        let sorted = values.sorted()
        return sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * fraction))]
    }
    static func request(_ extra: String = "") throws -> RemoteHTTPRequest {
        try RemoteHTTPRequest.parse(Data("GET /api/network HTTP/1.1\r\nHost: 127.0.0.1:8765\r\n\(extra)\r\n".utf8))!
    }

    @MainActor static func main() async throws {
        let mode = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "burst"
        try require(["single", "burst", "dense", "conditional", "rejected"].contains(mode), "Unknown workload")
        let count = mode == "dense" ? 96 : 19
        let concurrency = mode == "single" ? 1 : 8
        let rounds = ["single":128, "burst":256, "dense":128, "conditional":4096, "rejected":4096][mode]!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aa-actor-bench-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let records = ProcessDiscovery.parse("20 1 ?? 20 0 Mon Oct 12 09:00:00 2026 /fixture/iTerm2/iTermServer\n" + (0..<count).map {
            "\(900001 + $0) 20 ttys\(100 + $0) \(900001 + $0) \(900001 + $0) Mon Oct 12 09:00:00 2026 /fixture/codex"
        }.joined(separator: "\n"))
        let adapter = ScreenHostAdapter(screens: { targets in
            TerminalSnapshot(screens: targets.map { TerminalScreen(tty: $0.tty, contents: "Synthetic fixture output /src/main.swift\nREADY> ") })
        }, approve: { _, _, _ in .missingTarget }, reveal: { _ in nil }, input: { _, _, _, _ in
            throw AppError.message("This read-only fixture must never send input")
        })
        let engine = try ApprovalEngine(paths: AppPaths(directory: root), claudeRegistryReader: { _ in [] },
            processReader: { records }, screenAdapters: [.iterm: adapter])
        defer { engine.stop() }
        let sessions = records.filter { $0.agent == .codex }.map { record -> AgentSession in
            var value = AgentSession(id: record.key, agent: .codex, pid: record.pid, started: record.started,
                tty: "/dev/" + record.tty, cwd: "/fixture/project", terminal: .iterm)
            value.phase = .working; value.channel = .itermScreen
            value.terminalTitle = "합성 세션 · e\u{301} 🤖 · /fixture/project/src/main.swift"
            return value
        }
        engine.updateDiscovery(sessions, records: records)
        await engine.connectScreenHost(.iterm)
        let service = RemoteNetworkService(engine: engine, nodeID: "fixture-gateway", name: "Synthetic Mac",
            bonjourEnabled: false, loopbackOnly: true, discoveryAddresses: { [] }, onStatus: { _ in })
        defer { service.stop() }
        // No listener, engine.start, LAN discovery or original process lookup.
        let first = await service.handle(try request())
        try require(first.status == 200, "Initial response failed")
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let dashboard = try decoder.decode(RemoteDashboard.self, from: first.body)
        try require(dashboard.nodes.count == 1 && dashboard.nodes[0].state?.sessions.count == count, "Wrong synthetic inventory")
        try require(dashboard.nodes[0].state!.sessions.allSatisfy { $0.canRead && !$0.keys.isEmpty }, "Synthetic input capability projection missing")
        guard let tag = first.entityTag else { throw AppError.message("Missing dashboard validator") }
        let headers = mode == "conditional" ? "If-None-Match: \(tag)\r\n" : mode == "rejected" ? "Origin: http://foreign.example\r\n" : ""
        let expected = mode == "conditional" ? 304 : mode == "rejected" ? 403 : 200
        let input = try request(headers)
        for _ in 0..<8 {
            let response = await service.handle(input)
            try require(response.status == expected, "Warm response failed")
        }

        let stop = ProbeStop(), probe = ActorProbe()
        let ticker = Task.detached(priority: .medium) {
            while !stop.isFinished() {
                let requested = ProcessInfo.processInfo.systemUptime
                await MainActor.run { probe.record(requested) }
                try? await Task.sleep(for: .milliseconds(1))
            }
        }
        defer { stop.finish() }
        // Calibration is outside the timed request loop. One control callback
        // is outstanding at a time; these samples are queue delay, not input IO.
        try await Task.sleep(for: .milliseconds(20))
        probe.delays.removeAll(keepingCapacity: true)
        var latencies: [Double] = [], bytes = 0
        let childBefore = cpu(RUSAGE_CHILDREN), cpuBefore = cpu(), start = ProcessInfo.processInfo.systemUptime
        for _ in 0..<(rounds / concurrency) {
            let tasks = (0..<concurrency).map { _ in
                let sent = ProcessInfo.processInfo.systemUptime
                return Task(priority: .medium) { @MainActor in
                    let response = await service.handle(input)
                    return (response.status, response.body.count, ProcessInfo.processInfo.systemUptime - sent)
                }
            }
            for task in tasks {
                let (status, length, elapsed) = await task.value
                try require(status == expected, "Unexpected HTTP status")
                bytes += length; latencies.append(elapsed)
            }
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - start, used = cpu() - cpuBefore, children = cpu(RUSAGE_CHILDREN) - childBefore
        stop.finish(); await ticker.value
        try require(children == 0 && latencies.count == rounds, "Unexpected child or response count")
        try require(!probe.delays.isEmpty, "Control callback never ran")
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        let result: [String: Any] = ["mode": mode, "sessions": count, "concurrency": concurrency, "requests": rounds,
            "bodyBytes": first.body.count, "totalResponseBytes": bytes, "cpuSeconds": used, "wallSeconds": elapsed,
            "requestP50Seconds": percentile(latencies, 0.5), "requestP95Seconds": percentile(latencies, 0.95),
            "actorProbeCount": probe.delays.count, "actorP50Seconds": percentile(probe.delays, 0.5),
            "actorP95Seconds": percentile(probe.delays, 0.95), "actorMaxSeconds": probe.delays.max() ?? 0,
            "peakResidentBytes": usage.ru_maxrss, "timedChildCPUSeconds": children, "inputPosts": 0, "originalInputs": 0, "captures": 0,
            "scope": "Production HTTP parser and RemoteNetworkService.handle, one isolated synthetic gateway, eight independent MainActor request tasks at most, one outstanding medium-priority control callback sampled after each 1ms sleep. No listener, LAN IO, engine.start, original terminal/process lookup or input. Conditional and rejected requests are negative controls; not whole-app or phone latency."]
        print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
    }
}
