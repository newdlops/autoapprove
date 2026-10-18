import Foundation
import AutoApproveCore

@main struct ClaudeHookResourceBench {
    static func cpu() -> Double {
        var value = rusage(); getrusage(RUSAGE_SELF, &value)
        return Double(value.ru_utime.tv_sec + value.ru_stime.tv_sec)
            + Double(value.ru_utime.tv_usec + value.ru_stime.tv_usec) / 1_000_000
    }
    static func check(_ value: Bool, _ message: String) throws {
        guard value else { throw AppError.message(message) }
    }
    @MainActor static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aa-hook-resource-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let records = ProcessDiscovery.parse("82000 1 ttys080 82000 82000 Mon Oct 12 09:00:00 2026 /fixture/claude")
        let engine = try ApprovalEngine(paths: AppPaths(directory: root), claudeRegistryReader: { _ in [] }, processReader: { records })
        defer { engine.stop() }
        engine.updateDiscovery(ProcessDiscovery.sessions(records), records: records)
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970)), session = records[0].key
        func payload(_ command: String) -> JSONObject {
            ["autoapproveProtocol": 1, "requestID": UUID().uuidString,
             "autoapproveExpiresAt": now.addingTimeInterval(600).timeIntervalSince1970,
             "hook_event_name": "PreToolUse", "session_id": "fixture-provider", "agentPID": 82000,
             "agentStarted": records[0].started, "tool_name": "Bash",
             "cwd": root.path, "tool_input": ["command": command]]
        }
        func completed(_ request: JSONObject) throws -> JSONObject {
            let result = try engine.handleClaudeHook(request, at: now)
            guard let response = (result["autoapproveBridge"] as? JSONObject)?["response"] as? JSONObject else {
                throw AppError.message("Synthetic noninteractive hook did not complete")
            }
            try check(response.isEmpty, "A harmless event must return to the original Claude flow")
            return result
        }
        let large = "node tools/report.mjs --data '" + String(repeating: "synthetic ordinary report 한글 e\u{301} 🤖 output /fixture/data ", count: 150) + "'"
        let shortRequest = payload("printf 'fixture'"), largeRequest = payload(large)
        _ = try completed(shortRequest); _ = try completed(largeRequest)
        let shortBytes = try JSONSerialization.data(withJSONObject: shortRequest).count
        let largeBytes = try JSONSerialization.data(withJSONObject: largeRequest).count
        let unchangedAuditCount = engine.snapshot.events.count
        let workloads: [(String, Int)] = [("short-replay", 256), ("large-replay", 32), ("large-ack", 32), ("fresh-large", 32)]
        var results: [[String: Any]] = [], checksum = 0
        for (name, rounds) in workloads {
            var trials: [[String: Double]] = []
            for _ in 0..<3 {
                let startCPU = cpu(), startWall = ProcessInfo.processInfo.systemUptime
                for _ in 0..<rounds {
                    switch name {
                    case "short-replay": checksum += try completed(shortRequest).count
                    case "large-replay": checksum += try completed(largeRequest).count
                    case "large-ack": try engine.acknowledgeClaudeHook(largeRequest, at: now); checksum += 1
                    default: checksum += try completed(payload(large)).count
                    }
                }
                trials.append(["cpuSeconds": cpu() - startCPU, "wallSeconds": ProcessInfo.processInfo.systemUptime - startWall])
            }
            results.append(["name": name, "rounds": rounds, "trials": trials])
        }
        try check(engine.snapshot.events.count == unchangedAuditCount, "Replays or ACKs introduced approval audit")
        try check(engine.snapshot.sessions.contains { $0.id == session }, "Original synthetic session changed")
        print(String(decoding: try JSONSerialization.data(withJSONObject: [
            "workloads": results, "checksum": checksum, "sessions": 1,
            "payloadBytes": ["short": shortBytes, "large": largeBytes], "inputPosts": 0, "captures": 0,
            "scope": "Actual release Core, isolated synthetic Claude lifecycle; saved reply, ACK and fresh-request controls. No user profile, terminal input, source process, permission or screen operation."
        ], options: [.sortedKeys]), as: UTF8.self))
    }
}
