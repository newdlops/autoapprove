import Foundation
import CryptoKit
import AutoApproveCore

@main struct DashboardResponseBench {
    static func cpu() -> Double {
        var value = rusage(); getrusage(RUSAGE_SELF, &value)
        return Double(value.ru_utime.tv_sec + value.ru_stime.tv_sec)
            + Double(value.ru_utime.tv_usec + value.ru_stime.tv_usec) / 1_000_000
    }
    static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw AppError.message(message) }
    }
    static func object(_ data: Data) throws -> NSDictionary {
        guard let value = try JSONSerialization.jsonObject(with: data) as? NSDictionary else {
            throw AppError.message("Dashboard response is not an object")
        }
        return value
    }
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aa-dashboard-response-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let records = ProcessDiscovery.parse((0..<6).map {
            "\(82000+$0) 1 ttys\(80+$0) \(82000+$0) \(82000+$0) Mon Oct 12 09:00:00 2026 /fixture/codex"
        }.joined(separator: "\n"))
        let engine = try ApprovalEngine(paths: AppPaths(directory: root), processReader: { records })
        defer { engine.stop() }
        engine.updateDiscovery(ProcessDiscovery.sessions(records), records: records)
        let service = RemoteNetworkService(engine: engine, nodeID: "fixture-gateway", bonjourEnabled: false,
            discoveryAddresses: { [] }, onStatus: { _ in })
        defer { service.stop() }
        var original = try await service.dashboard()
        guard let template = original.nodes.first, template.state?.sessions.count == 6 else {
            throw AppError.message("Expected six synthetic sessions")
        }
        original.nodes = (0..<4).map { index in
            var node = template
            node.id = "fixture-node-\(index)"; node.local = index == 0
            node.name = "합성 Mac \(index) · e\u{301} 🤖 /fixture/project"
            node.state?.id = node.id; node.state?.name = node.name
            for row in node.state!.sessions.indices {
                node.state!.sessions[row].title = "합성 세션 \(row) · quoted \"updatedAt\":\"1970-01-01T00:00:00Z\" · /src/main.swift"
            }
            return node
        }
        original.updatedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let first = try original.response(ifNoneMatch: nil)
        guard let tag = first.entityTag else { throw AppError.message("Missing dashboard validator") }
        var cases = 0
        let dates: [Double] = [-62_135_596_800, -1, 0, 1_800_000_000.5, 4_102_444_800]
        for date in dates {
            var value = original; value.updatedAt = Date(timeIntervalSince1970: date)
            let response = try value.response(ifNoneMatch: nil)
            try check(response.status == 200 && response.observedAt == value.updatedAt, "Observation metadata changed")
            // Independent legacy representation: compare every decoded field,
            // including nested text resembling the root date member.
            try check(try object(response.body) == object(RemoteHTTPResponse.json(value).body), "Dashboard body changed")
            let same = try value.response(ifNoneMatch: "\"other\", " + tag)
            try check(same.status == 304 && same.body.isEmpty && same.observedAt == value.updatedAt, "Observation time invalidated content")
            cases += 1
        }
        var changed = original
        changed.nodes[2].state?.sessions[0].session.automatic.toggle()
        changed.nodes[2].state?.sessions[0].keys = ["text", "enter", "characters"]
        changed.nodes[2].name += " /\\\n\u{0000}\u{0004}"
        changed.discovery = "nested suffix: ,\"updatedAt\":\"1970-01-01T00:00:00Z\"}"
        let fresh = try changed.response(ifNoneMatch: tag)
        try check(fresh.status == 200 && fresh.entityTag != tag, "Fresh controls failed to invalidate dashboard")
        try check(try object(fresh.body) == object(RemoteHTTPResponse.json(changed).body), "Fresh control body changed")
        try check(try original.response(ifNoneMatch: "*").status == 304, "Wildcard validator changed")
        cases += 2
        let rounds = 96
        let inputs: [(String, RemoteDashboard, String?)] = [
            ("full", original, nil), ("unchanged", original, tag), ("changed", changed, tag)
        ]
        var workloads: [[String: Any]] = [], checksum = 0
        for (name, input, condition) in inputs {
            for _ in 0..<8 { checksum += try input.response(ifNoneMatch: condition).body.count }
            var trials: [[String: Double]] = []
            for _ in 0..<3 {
                let startCPU = cpu(), startWall = ProcessInfo.processInfo.systemUptime
                for index in 0..<rounds {
                    var current = input; current.updatedAt = input.updatedAt.addingTimeInterval(Double(index))
                    let response = try current.response(ifNoneMatch: condition)
                    try check(response.status == (name == "unchanged" ? 304 : 200), "Unexpected HTTP status")
                    try check(response.observedAt == current.updatedAt, "Response reused an old observation time")
                    checksum += response.body.count
                }
                trials.append(["cpuSeconds": cpu() - startCPU, "wallSeconds": ProcessInfo.processInfo.systemUptime - startWall])
            }
            workloads.append(["name": name, "rounds": rounds, "trials": trials])
        }
        print(String(decoding: try JSONSerialization.data(withJSONObject: [
            "correctnessCases": cases, "sessions": 24, "nodes": 4, "bodyBytes": first.body.count,
            "workloads": workloads, "checksum": checksum, "inputPosts": 0, "captures": 0,
            "scope": "Actual release Core response function, same synthetic 24-session dashboard. Encoding, hashing and body preparation only; not discovery, terminal reads, whole-app CPU or physical phone latency."
        ], options: [.sortedKeys]), as: UTF8.self))
    }
}
